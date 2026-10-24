// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// RefreshEngineTests.swift - ports of the refresh, clock, cool-down and offline cases of
// src/ui/test-window.c (registrations at test-window.c:4105-4206) to the RefreshEngine,
// driven by a ManualClock.
//
// Mapping of the C fixture: the window is the engine's visible input, the GNetworkMonitor
// is setOnline, the gate keeps a request in flight (here: the test reports the end when it
// wants), warp_clocks(s) is clock.advance(by: s s) (the shim moves the monotonic and the
// real clock together, test-window.c:3217-3222). The C fixture registers TWO fake providers
// and every request of a place reaches both, so wx_fake_provider_get_fetch_count(fx->a)
// counts the engine's fetches and fetches_of(fx) (test-window.c:1801-1805, a + b) counts
// two per fetch. wxt_pump_ms(n) is clock.advance(by: n ms).

import Testing
@testable import WeatherCore

@MainActor private final class Host {
    let clock = ManualClock()
    var engine: RefreshEngine!
    var fetches: [(id: UInt64, key: String)] = []
    var cancels: [UInt64] = []
    var displayed: [Int64] = []
    /// true: a cancel is reported at once (inside the callback), like a GCancellable whose
    /// operation completes synchronously; false: the test reports it.
    var completeCancelsAtOnce = true

    init(online: Bool = true) {
        engine = RefreshEngine(
            clock: clock, online: online,
            fetch: { [weak self] id, key in self?.fetches.append((id, key)) },
            cancel: { [weak self] id in
                guard let self else { return }
                self.cancels.append(id)
                if self.completeCancelsAtOnce {
                    self.engine.requestFinished(id: id, result: .cancelled)
                }
            },
            display: { [weak self] now in self?.displayed.append(now) })
    }

    var fetchCount: Int { fetches.count }
    // No force unwraps: a failing expectation must not crash the test process (learning L3).
    var lastID: UInt64 { fetches.last?.id ?? 0 }
    var loading: Bool { engine.state(of: Self.miami)?.loading == true }
    var stale: Bool { engine.state(of: Self.miami)?.stale == true }
    /// wx_row_item_get_now_s of the items: the last time the display clock gave them.
    var nowS: Int64 { displayed.last ?? -1 }

    func finishLast(_ result: RefreshEngine.Completion) {
        engine.requestFinished(id: lastID, result: result)
    }

    func warp(seconds: Int64) async {
        await clock.advance(by: seconds * 1_000_000)
    }

    func pump(ms: Int64) async {
        await clock.advance(by: ms * 1000)
    }

    /// store_places + fx_start: the places, the selection of the first one, the window shown.
    func start(_ keys: [String] = [Host.miami]) {
        engine.setPlaces(keys)
        engine.select(keys.first)
        engine.setVisible(true)
    }

    /// start + WAIT_FORECAST + !loading: the start-up request succeeded.
    func startLoaded() {
        start()
        finishLast(.ok)
    }

    static let miami = "25.7617,-80.1918"
    static let orlando = "28.5383,-81.3792"
    static let tampa = "27.9506,-82.4572"
    static let rateLimited = WxError(.rateLimited, "HTTP 429: rate limited")
    static let network = WxError(.network, "network down")
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RefreshEngineTests {
    // MARK: - Constants

    @Test func constantsAreTheCValues() {
        #expect(RefreshEngine.clockTickS == 60)          // wx-app.h:155
        #expect(RefreshEngine.refreshMinGapS == 10)      // wx-app.h:158
        #expect(RefreshEngine.rateLimitCooldownS == 60)  // wx-app.h:161
        // test-window.c:1717: G_STATIC_ASSERT(WX_APP_RATE_LIMIT_COOLDOWN_S > WX_APP_REFRESH_MIN_GAP_S)
        #expect(RefreshEngine.rateLimitCooldownS > RefreshEngine.refreshMinGapS)
    }

    // MARK: - /window/refresh/*

    // C: /window/refresh/loading-then-ok (test-window.c:1402-1426)
    @Test func refreshLoadingThenOk() {
        let h = Host()
        h.start()
        #expect(h.loading)                               // test-window.c:1409
        #expect(h.fetchCount == 1)                       // test-window.c:1415
        h.finishLast(.ok)
        #expect(!h.loading)                              // test-window.c:1418
        #expect(!h.stale)                                // test-window.c:1419
    }

    // C: /window/refresh/failed-then-recovers (test-window.c:1445-1475)
    @Test func refreshFailedThenRecovers() async {
        let h = Host()
        h.start()
        h.finishLast(.failed(WxError(.network, "fake-a: scripted failure")))
        #expect(!h.loading)                              // test-window.c:1453
        #expect(h.stale)                                 // test-window.c:1455
        await h.warp(seconds: RefreshEngine.refreshMinGapS + 1)  // test-window.c:1465
        #expect(h.engine.canRefresh)                     // test-window.c:1466
        h.engine.refreshSelected()                       // test-window.c:1467
        #expect(h.fetchCount == 2)
        h.finishLast(.ok)
        #expect(!h.loading)                              // test-window.c:1469
        #expect(!h.stale)                                // test-window.c:1470
    }

    // C: /window/refresh/stale-keeps-data (test-window.c:1523-1555)
    @Test func refreshStaleKeepsDataUntilRecovery() async {
        let h = Host()
        h.start()
        h.finishLast(.failed(Host.network))              // test-window.c:1529-1530
        #expect(h.stale)                                 // test-window.c:1533
        #expect(!h.loading)                              // test-window.c:1534
        await h.warp(seconds: RefreshEngine.refreshMinGapS + 1)  // test-window.c:1547
        h.engine.refreshSelected()                       // test-window.c:1550
        #expect(h.stale, "starting a refresh never clears the mark (wx-app.h:56-59)")
        h.finishLast(.ok)
        #expect(!h.stale)                                // test-window.c:1551
    }

    // C: /window/refresh/offline (test-window.c:1564-1603)
    @Test func refreshOfflineCancelsAndResumes() async {
        let h = Host()
        h.start()
        #expect(h.loading)                               // test-window.c:1571
        #expect(h.fetchCount == 1)                       // test-window.c:1572
        h.engine.setOnline(false)                        // test-window.c:1573
        #expect(h.engine.isOffline)                      // test-window.c:1574
        #expect(h.cancels == [h.lastID])
        #expect(!h.loading)                              // test-window.c:1575
        #expect(!h.stale)                                // test-window.c:1577
        #expect(!h.engine.canRefresh)                    // test-window.c:1578
        h.engine.refreshSelected()
        await h.pump(ms: 300)                            // test-window.c:1581
        #expect(h.fetchCount == 1)                       // test-window.c:1582
        h.engine.setOnline(true)                         // test-window.c:1584
        #expect(!h.engine.isOffline)                     // test-window.c:1585
        #expect(h.fetchCount == 2)                       // test-window.c:1586
        h.finishLast(.ok)                                // test-window.c:1587
        #expect(h.fetchCount == 2)                       // test-window.c:1589
        #expect(h.engine.canRefresh)                     // test-window.c:1591
    }

    // C: /window/refresh/hidden-requests-nothing (test-window.c:1606-1629)
    @Test func refreshHiddenRequestsNothing() async {
        let h = Host()
        h.start()
        #expect(h.loading)                               // test-window.c:1613
        h.engine.setVisible(false)                       // test-window.c:1614
        #expect(!h.loading)                              // test-window.c:1616
        #expect(h.cancels.count == 1)
        let before = h.fetchCount                        // test-window.c:1618
        await h.pump(ms: 400)                            // test-window.c:1619
        #expect(h.fetchCount == before)                  // test-window.c:1620
        #expect(!h.stale)                                // test-window.c:1621
        h.engine.setVisible(true)                        // test-window.c:1623
        #expect(h.loading)                               // test-window.c:1626
        #expect(h.fetchCount == before + 1)              // test-window.c:1627
    }

    // C: /window/refresh/button-forces-request (test-window.c:1632-1671)
    @Test func refreshButtonForcesANewRequest() async {
        let h = Host()
        h.completeCancelsAtOnce = false
        h.start()
        #expect(h.loading)                               // test-window.c:1639
        #expect(!h.engine.canRefresh)                    // test-window.c:1642
        await h.warp(seconds: RefreshEngine.refreshMinGapS + 1)  // test-window.c:1643
        h.engine.refreshSelected()                       // test-window.c:1644
        #expect(h.fetchCount == 1)                       // test-window.c:1646
        #expect(h.cancels.isEmpty)                       // test-window.c:1647
        h.finishLast(.ok)                                // test-window.c:1648
        #expect(!h.loading)                              // test-window.c:1650
        #expect(h.engine.canRefresh)                     // test-window.c:1651
        await h.warp(seconds: RefreshEngine.refreshMinGapS + 1)  // test-window.c:1654
        h.engine.refreshSelected()                       // test-window.c:1655
        #expect(h.fetchCount == 2)                       // test-window.c:1656
        #expect(h.loading)                               // test-window.c:1657
        #expect(!h.engine.canRefresh)                    // test-window.c:1658
        h.engine.refreshSelected()                       // test-window.c:1660-1661
        h.engine.refreshSelected()
        #expect(h.fetchCount == 2)                       // test-window.c:1663
        #expect(h.cancels.isEmpty)                       // test-window.c:1664
        h.finishLast(.ok)                                // test-window.c:1665
        #expect(!h.loading)                              // test-window.c:1666
        #expect(h.engine.canRefresh)                     // test-window.c:1667
        #expect(h.fetchCount == 2)                       // test-window.c:1668
    }

    // C: /window/refresh/rate-limited (test-window.c:1676-1709): a manual refresh within
    // WX_APP_REFRESH_MIN_GAP_S of the last request is dropped, not deferred.
    @Test func refreshIsRateLimited() async {
        let h = Host()
        h.startLoaded()
        #expect(h.fetchCount == 1)                       // test-window.c:1685
        for i in 0..<300 {                               // test-window.c:1687-1692
            h.engine.refreshSelected()
            if i % 10 == 0 { await h.pump(ms: 0) }
        }
        await h.pump(ms: 100)                            // test-window.c:1693
        #expect(h.fetchCount == 1)                       // test-window.c:1694
        // Dropped, not deferred: nothing starts when the gap ends by itself.
        await h.warp(seconds: RefreshEngine.refreshMinGapS + 1)  // test-window.c:1698
        #expect(h.fetchCount == 1, "a dropped refresh is not queued (wx-app.h:74, wx-app.c:1621-1625)")
        for i in 0..<300 {                               // test-window.c:1699-1704
            h.engine.refreshSelected()
            if i % 10 == 0 { await h.pump(ms: 0) }
        }
        await h.pump(ms: 100)                            // test-window.c:1705
        #expect(h.fetchCount == 2)                       // test-window.c:1706
    }

    // C: /window/refresh/rate-limit-cool-down (test-window.c:1715-1758)
    @Test func rateLimitedPlaceWaitsForTheCoolDown() async {
        let h = Host()
        h.startLoaded()
        await h.pump(ms: 300)                            // test-window.c:1725
        #expect(h.fetchCount == 1)                       // test-window.c:1726
        await h.warp(seconds: RefreshEngine.refreshMinGapS + 1)  // test-window.c:1730
        h.engine.refreshSelected()                       // test-window.c:1731
        #expect(h.fetchCount == 2)                       // test-window.c:1732
        h.finishLast(.failed(Host.rateLimited))          // test-window.c:1728-1729
        #expect(h.stale)                                 // test-window.c:1733
        #expect(!h.loading)                              // test-window.c:1734
        await h.warp(seconds: RefreshEngine.refreshMinGapS + 1)  // test-window.c:1736
        #expect(h.engine.canRefresh)                     // test-window.c:1737
        for _ in 0..<20 { h.engine.refreshSelected() }   // test-window.c:1738-1739
        await h.pump(ms: 100)                            // test-window.c:1740
        #expect(h.fetchCount == 2)                       // test-window.c:1741
        await h.warp(seconds: RefreshEngine.rateLimitCooldownS - RefreshEngine.refreshMinGapS)  // test-window.c:1743
        #expect(h.fetchCount == 3)                       // test-window.c:1744
        h.finishLast(.failed(Host.rateLimited))
        #expect(!h.loading)                              // test-window.c:1745
        #expect(h.stale)                                 // test-window.c:1746
        await h.warp(seconds: RefreshEngine.rateLimitCooldownS + 1)  // test-window.c:1751
        #expect(h.fetchCount == 4)                       // test-window.c:1752
        h.finishLast(.failed(Host.network))              // test-window.c:1749-1750
        #expect(!h.loading)                              // test-window.c:1753
        await h.warp(seconds: RefreshEngine.refreshMinGapS + 1)  // test-window.c:1754
        h.engine.refreshSelected()                       // test-window.c:1755
        #expect(h.fetchCount == 5)                       // test-window.c:1756
    }

    // C: /window/refresh/local-refusal-no-cool-down (test-window.c:1765-1798). The service
    // reports a provider's local refusal next to a real failure as the real failure
    // (test-window.c:1776: "fake-a: scripted failure", an HTTP error); only a server's rate
    // limit starts the cool-down.
    @Test func localRefusalStartsNoCoolDown() async {
        let h = Host()
        h.start()
        h.finishLast(.failed(WxError(.http, "fake-a: scripted failure")))  // test-window.c:1767, 1776
        #expect(h.stale && !h.loading)                   // test-window.c:1775
        await h.pump(ms: 300)                            // test-window.c:1777
        #expect(h.fetchCount == 1)                       // test-window.c:1778
        await h.warp(seconds: RefreshEngine.refreshMinGapS + 1)  // test-window.c:1781
        h.engine.refreshSelected()                       // test-window.c:1782
        #expect(h.fetchCount == 2)                       // test-window.c:1783
        h.finishLast(.failed(WxError(.rateLimited, "gate: HTTP 429: rate limited")))  // test-window.c:1787-1789
        #expect(!h.loading)                              // test-window.c:1788
        await h.warp(seconds: RefreshEngine.refreshMinGapS + 1)  // test-window.c:1790
        for _ in 0..<5 { h.engine.refreshSelected() }    // test-window.c:1791-1792
        await h.pump(ms: 100)                            // test-window.c:1793
        #expect(h.fetchCount == 2)                       // test-window.c:1794
        await h.warp(seconds: RefreshEngine.rateLimitCooldownS - RefreshEngine.refreshMinGapS)  // test-window.c:1795
        #expect(h.fetchCount == 3)                       // test-window.c:1796
    }

    // C: /window/refresh/rate-limit-out-of-scheduler (test-window.c:1812-1867)
    @Test func rateLimitedPlaceIsOutOfTheScheduler() async {
        let h = Host()
        h.startLoaded()
        await h.pump(ms: 300)                            // test-window.c:1821
        #expect(h.fetchCount * 2 == 2)                   // test-window.c:1822 (fetches_of == 2)
        await h.warp(seconds: RefreshEngine.refreshMinGapS + 1)  // test-window.c:1825
        h.engine.refreshSelected()                       // test-window.c:1826
        #expect(h.fetchCount * 2 == 4)                   // test-window.c:1827
        h.finishLast(.failed(Host.rateLimited))          // test-window.c:1823-1824
        #expect(h.stale && !h.loading)                   // test-window.c:1828
        for _ in 0..<20 {                                // test-window.c:1832-1835
            h.engine.windowFocused()
            await h.pump(ms: 0)
        }
        for _ in 0..<10 {                                // test-window.c:1836-1840
            h.engine.setVisible(false)
            h.engine.setVisible(true)
            await h.pump(ms: 0)
        }
        h.engine.setOnline(false)                        // test-window.c:1841-1842
        h.engine.setOnline(true)
        h.engine.sourcesChanged()                        // test-window.c:1843-1844
        h.engine.sourcesChanged()
        await h.warp(seconds: RefreshEngine.rateLimitCooldownS / 2)  // test-window.c:1845
        for _ in 0..<5 {                                 // test-window.c:1846-1849
            h.engine.windowFocused()
            await h.pump(ms: 0)
        }
        await h.pump(ms: 300)                            // test-window.c:1850
        #expect(h.fetchCount * 2 == 4)                   // test-window.c:1851
        #expect(!h.loading)                              // test-window.c:1852
        #expect(h.stale)                                 // test-window.c:1853
        await h.warp(seconds: RefreshEngine.rateLimitCooldownS / 2 + 2)  // test-window.c:1856
        #expect(h.fetchCount * 2 == 6)                   // test-window.c:1857
        h.finishLast(.failed(Host.rateLimited))          // test-window.c:1861
        #expect(!h.loading)                              // test-window.c:1858
        await h.pump(ms: 300)                            // test-window.c:1859
        #expect(h.fetchCount * 2 == 6)                   // test-window.c:1860
        for _ in 0..<5 { h.engine.windowFocused() }      // test-window.c:1862-1863
        await h.pump(ms: 100)                            // test-window.c:1864
        #expect(h.fetchCount * 2 == 6)                   // test-window.c:1865
    }

    // C: /window/refresh/rate-limit-ends-while-hidden (test-window.c:1872-1913)
    @Test func rateLimitCoolDownEndingWhileHidden() async {
        let h = Host()
        h.startLoaded()
        await h.pump(ms: 300)                            // test-window.c:1881
        await h.warp(seconds: RefreshEngine.refreshMinGapS + 1)  // test-window.c:1884
        h.engine.refreshSelected()                       // test-window.c:1885
        #expect(h.fetchCount * 2 == 4)                   // test-window.c:1886
        h.finishLast(.failed(Host.rateLimited))          // test-window.c:1882-1883
        #expect(!h.loading)                              // test-window.c:1887
        let before = h.fetchCount * 2                    // test-window.c:1888
        h.engine.setVisible(false)                       // test-window.c:1890
        await h.warp(seconds: RefreshEngine.rateLimitCooldownS + 1)  // test-window.c:1891
        await h.pump(ms: 300)                            // test-window.c:1892
        // test-window.c:1893: no timer while hidden (no source with the app as user data).
        #expect(!h.engine.refreshTimerArmed && !h.engine.displayClockRunning)
        #expect(h.clock.pendingSleeperCount == 0)
        #expect(h.fetchCount * 2 == before)              // test-window.c:1894
        h.engine.setVisible(true)                        // test-window.c:1895
        #expect(h.fetchCount * 2 == before + 2)          // test-window.c:1896
        h.finishLast(.failed(Host.rateLimited))
        #expect(!h.loading)                              // test-window.c:1897
        await h.pump(ms: 300)                            // test-window.c:1898
        #expect(h.fetchCount * 2 == before + 2)          // test-window.c:1899
        await h.warp(seconds: RefreshEngine.refreshMinGapS + 1)  // test-window.c:1902
        h.engine.setOnline(false)                        // test-window.c:1903
        await h.warp(seconds: RefreshEngine.rateLimitCooldownS + 1)  // test-window.c:1904
        await h.pump(ms: 300)                            // test-window.c:1905
        #expect(h.fetchCount * 2 == before + 2)          // test-window.c:1906
        h.engine.setOnline(true)                         // test-window.c:1907
        #expect(h.fetchCount * 2 == before + 4)          // test-window.c:1908
        h.finishLast(.failed(Host.rateLimited))
        #expect(!h.loading)                              // test-window.c:1909
        await h.pump(ms: 300)                            // test-window.c:1910
        #expect(h.fetchCount * 2 == before + 4)          // test-window.c:1911
    }

    // C: /window/refresh/rate-limit-end-is-timed (test-window.c:1918-1942)
    @Test func rateLimitCoolDownEndIsTimed() async {
        let h = Host()
        h.startLoaded()
        await h.pump(ms: 300)                            // test-window.c:1927
        await h.warp(seconds: RefreshEngine.refreshMinGapS + 1)  // test-window.c:1930
        h.engine.refreshSelected()                       // test-window.c:1931
        #expect(h.fetchCount * 2 == 4)                   // test-window.c:1932
        h.finishLast(.failed(Host.rateLimited))          // test-window.c:1928-1929
        #expect(!h.loading)                              // test-window.c:1933
        await h.pump(ms: 300)                            // test-window.c:1934
        #expect(h.fetchCount * 2 == 4)                   // test-window.c:1935
        #expect(h.engine.refreshTimerArmed, "the end of the cool-down is a timer deadline")
        await h.warp(seconds: RefreshEngine.rateLimitCooldownS + 1)  // test-window.c:1936
        #expect(h.fetchCount * 2 == 6)                   // test-window.c:1937
        h.finishLast(.failed(Host.rateLimited))
        #expect(!h.loading)                              // test-window.c:1938
        await h.pump(ms: 300)                            // test-window.c:1939
        #expect(h.fetchCount * 2 == 6)                   // test-window.c:1940
    }

    // C: /window/refresh/switch-flips-coalesced (test-window.c:1947-1978)
    @Test func providerSwitchFlipsAreCoalesced() async {
        let h = Host()
        h.start([Host.miami, Host.orlando, Host.tampa])  // test-window.c:1951-1952
        #expect(h.fetchCount == 3)
        for f in h.fetches { h.engine.requestFinished(id: f.id, result: .ok) }  // test-window.c:1953-1956
        #expect(h.fetchCount == 3)                       // test-window.c:1957
        for i in 0..<40 {                                // test-window.c:1958-1962
            h.engine.sourcesChanged()
            if i % 5 == 0 { await h.pump(ms: 0) }
        }
        await h.pump(ms: 100)                            // test-window.c:1964
        #expect(h.fetchCount == 3)                       // test-window.c:1965
        await h.warp(seconds: RefreshEngine.refreshMinGapS + 1)  // test-window.c:1966
        #expect(h.fetchCount == 6)                       // test-window.c:1967
        #expect(Set(h.fetches.dropFirst(3).map(\.key)) == [Host.miami, Host.orlando, Host.tampa], "each place, once")
        for f in h.fetches.dropFirst(3) { h.engine.requestFinished(id: f.id, result: .ok) }  // test-window.c:1968-1969
        await h.pump(ms: 200)                            // test-window.c:1970
        #expect(h.fetchCount == 6)                       // test-window.c:1971
        h.engine.sourcesChanged()                        // test-window.c:1974
        await h.pump(ms: 100)                            // test-window.c:1975
        #expect(h.fetchCount == 6)                       // test-window.c:1976
    }

    // C: /window/refresh/switch-offline-applied-later (test-window.c:1983-2006)
    @Test func providerSwitchWhileOfflineIsAppliedLater() async {
        let h = Host()
        h.startLoaded()                                  // test-window.c:1988-1991
        h.engine.setOnline(false)                        // test-window.c:1992
        h.engine.sourcesChanged()                        // test-window.c:1993-1995
        h.engine.sourcesChanged()
        h.engine.sourcesChanged()
        await h.warp(seconds: RefreshEngine.refreshMinGapS + 1)  // test-window.c:1996
        await h.pump(ms: 100)                            // test-window.c:1997
        #expect(h.fetchCount == 1)                       // test-window.c:1998
        h.engine.setOnline(true)                         // test-window.c:1999
        #expect(h.fetchCount == 2)                       // test-window.c:2000
        h.finishLast(.ok)
        #expect(!h.loading)                              // test-window.c:2001
        await h.pump(ms: 100)                            // test-window.c:2002
        #expect(h.fetchCount == 2)                       // test-window.c:2003
    }

    /// stale_fx_new (test-window.c:2031-2058): the start-up refresh failed, a forced refresh
    /// (after the gap) is in flight; the place is marked stale.
    private func staleFixture(_ h: Host) async {
        h.start()
        #expect(h.loading)                               // test-window.c:2042
        h.finishLast(.failed(Host.network))              // test-window.c:2043
        #expect(h.stale)                                 // test-window.c:2044
        #expect(!h.loading)                              // test-window.c:2045
        #expect(h.fetchCount == 1)                       // test-window.c:2050
        await h.warp(seconds: RefreshEngine.refreshMinGapS + 1)  // test-window.c:2052
        h.engine.refreshSelected()                       // test-window.c:2053
        #expect(h.fetchCount == 2)                       // test-window.c:2054
        #expect(h.loading)                               // test-window.c:2055
        #expect(h.stale)                                 // test-window.c:2056 (stale_fx_assert_marked)
    }

    // C: /window/refresh/stale-kept-when-cancelled-by-hide (test-window.c:2063-2095)
    @Test func forcedRefreshCancelledByHideKeepsTheStaleMark() async {
        let h = Host()
        await staleFixture(h)
        h.engine.setVisible(false)                       // test-window.c:2067
        #expect(!h.loading)                              // test-window.c:2069
        #expect(h.cancels.count == 1)                    // test-window.c:2071
        #expect(h.stale)                                 // test-window.c:2072
        h.engine.setVisible(true)                        // test-window.c:2074
        #expect(h.fetchCount == 3)                       // test-window.c:2077
        #expect(h.loading)                               // test-window.c:2078
        #expect(h.stale)                                 // test-window.c:2081
        h.finishLast(.failed(Host.network))              // test-window.c:2084
        #expect(!h.loading)                              // test-window.c:2085
        #expect(h.stale)                                 // test-window.c:2086
        await h.warp(seconds: RefreshEngine.refreshMinGapS + 1)  // test-window.c:2087
        h.engine.refreshSelected()                       // test-window.c:2088
        #expect(h.fetchCount == 4)                       // test-window.c:2089
        h.finishLast(.ok)                                // test-window.c:2090
        #expect(!h.stale)                                // test-window.c:2091
    }

    // C: /window/refresh/stale-kept-when-cancelled-by-offline (test-window.c:2098-2116)
    @Test func forcedRefreshCancelledByOfflineKeepsTheStaleMark() async {
        let h = Host()
        await staleFixture(h)
        h.engine.setOnline(false)                        // test-window.c:2102
        #expect(!h.loading)                              // test-window.c:2103
        #expect(h.cancels.count == 1)                    // test-window.c:2104
        #expect(h.stale)                                 // test-window.c:2105
        h.engine.setOnline(true)                         // test-window.c:2110
        #expect(h.fetchCount == 3)                       // test-window.c:2111
        #expect(h.stale)                                 // test-window.c:2112
    }

    // C: /window/refresh/stale-kept-during-provider-switch (test-window.c:2121-2141)
    @Test func providerSwitchDuringForcedRefreshKeepsTheStaleMark() async {
        let h = Host()
        await staleFixture(h)
        h.engine.sourcesChanged()                        // test-window.c:2125
        await h.pump(ms: 0)                              // test-window.c:2126
        #expect(h.cancels.isEmpty)                       // test-window.c:2127
        #expect(h.fetchCount == 2)                       // test-window.c:2128
        #expect(h.stale)                                 // test-window.c:2129
        h.finishLast(.failed(Host.network))              // test-window.c:2130
        #expect(!h.loading)                              // test-window.c:2131
        #expect(h.stale)                                 // test-window.c:2132
        await h.warp(seconds: RefreshEngine.refreshMinGapS + 1)  // test-window.c:2134
        #expect(h.fetchCount == 3)                       // test-window.c:2135
        #expect(h.loading)                               // test-window.c:2136
        #expect(h.stale)                                 // test-window.c:2137
        h.finishLast(.ok)                                // test-window.c:2138
        #expect(!h.stale)                                // test-window.c:2139
    }

    // C: /window/app/refresh-and-switch-edge-cases (test-window.c:2906-2929)
    @Test func refreshWithoutSelectionOrOfflineDoesNothing() async {
        let h = Host()
        h.engine.setVisible(true)                        // fx_start (test-window.c:2910)
        h.engine.refreshSelected()                       // test-window.c:2911: no place
        #expect(h.fetchCount == 0)                       // test-window.c:2912
        h.engine.setPlaces([Host.miami])                 // test-window.c:2914
        h.engine.select(Host.miami)
        h.finishLast(.ok)                                // test-window.c:2915
        let n = h.fetchCount                             // test-window.c:2916
        h.engine.setOnline(false)                        // test-window.c:2917
        h.engine.refreshSelected()                       // test-window.c:2918
        h.engine.sourcesChanged()                        // test-window.c:2919
        await h.pump(ms: 200)                            // test-window.c:2920
        #expect(h.fetchCount == n)                       // test-window.c:2921
    }

    // MARK: - /window/clock/*

    // C: /window/clock/tick-and-stop (test-window.c:3225-3256)
    @Test func clockTicksWhileVisibleOnly() async {
        let h = Host()
        h.startLoaded()                                  // test-window.c:3236-3238
        let first = h.nowS                               // test-window.c:3239
        await h.warp(seconds: RefreshEngine.clockTickS + 1)  // test-window.c:3240
        #expect(h.nowS - first >= RefreshEngine.clockTickS)  // test-window.c:3241
        h.engine.setVisible(false)                       // test-window.c:3243
        #expect(!h.engine.displayClockRunning)
        let stopped = h.nowS                             // test-window.c:3245
        await h.warp(seconds: 3 * RefreshEngine.clockTickS)  // test-window.c:3246
        await h.pump(ms: 300)                            // test-window.c:3247
        #expect(h.nowS == stopped)                       // test-window.c:3248
        h.engine.setVisible(true)                        // test-window.c:3250
        #expect(h.nowS - stopped >= 3 * RefreshEngine.clockTickS)  // test-window.c:3251
        let again = h.nowS                               // test-window.c:3252
        await h.warp(seconds: RefreshEngine.clockTickS + 1)  // test-window.c:3253
        #expect(h.nowS - again >= RefreshEngine.clockTickS)  // test-window.c:3254
    }

    // C: /window/clock/stops-while-offline (test-window.c:3261-3310)
    @Test func clockStopsWhileOffline() async {
        let h = Host()
        h.startLoaded()                                  // test-window.c:3266-3269
        let first = h.nowS                               // test-window.c:3270
        await h.warp(seconds: RefreshEngine.clockTickS + 1)  // test-window.c:3271
        #expect(h.nowS - first >= RefreshEngine.clockTickS)  // test-window.c:3272
        await h.warp(seconds: 5)                         // test-window.c:3275
        h.engine.setOnline(false)                        // test-window.c:3276
        let atTransition = h.nowS                        // test-window.c:3277
        #expect(atTransition - first >= RefreshEngine.clockTickS + 5)  // test-window.c:3278
        #expect(!h.engine.displayClockRunning)
        for _ in 0..<3 {                                 // test-window.c:3279-3283
            await h.warp(seconds: RefreshEngine.clockTickS + 1)
            await h.pump(ms: 300)
            #expect(h.nowS == atTransition)
        }
        #expect(h.fetchCount == 1)                       // test-window.c:3284
        h.engine.setOnline(true)                         // test-window.c:3287
        let back = h.nowS                                // test-window.c:3288
        #expect(back - atTransition >= 3 * RefreshEngine.clockTickS)  // test-window.c:3289
        await h.warp(seconds: RefreshEngine.clockTickS + 1)  // test-window.c:3290
        #expect(h.nowS - back >= RefreshEngine.clockTickS)  // test-window.c:3291
        h.engine.setOnline(false)                        // test-window.c:3294
        h.engine.setVisible(false)                       // test-window.c:3295
        let hidden = h.nowS                              // test-window.c:3297
        await h.warp(seconds: 2 * RefreshEngine.clockTickS + 1)  // test-window.c:3298
        await h.pump(ms: 300)                            // test-window.c:3299
        #expect(h.nowS == hidden)                        // test-window.c:3300
        h.engine.setVisible(true)                        // test-window.c:3301
        let shown = h.nowS                               // test-window.c:3304
        #expect(shown - hidden >= 2 * RefreshEngine.clockTickS)  // test-window.c:3305
        #expect(!h.engine.displayClockRunning)
        await h.warp(seconds: 2 * RefreshEngine.clockTickS + 1)  // test-window.c:3306
        await h.pump(ms: 300)                            // test-window.c:3307
        #expect(h.nowS == shown)                         // test-window.c:3308
    }

    // C: /window/clock/periodic-round (test-window.c:3313-3333)
    @Test func periodicRoundAfterTenMinutes() async {
        let h = Host()
        h.startLoaded()                                  // test-window.c:3318-3321
        #expect(h.fetchCount == 1)                       // test-window.c:3322
        await h.warp(seconds: 9 * 60 - 30)               // test-window.c:3324
        await h.pump(ms: 200)                            // test-window.c:3325
        #expect(h.fetchCount == 1)                       // test-window.c:3326
        await h.warp(seconds: RefreshScheduler.periodUS / 1_000_000)  // test-window.c:3328
        #expect(h.fetchCount == 2)                       // test-window.c:3329
        h.finishLast(.ok)
        #expect(!h.loading)                              // test-window.c:3330
    }

    // MARK: - Clock and event rounds (wx-app.h:47-102; storage-sched-service.md:371-403)

    // C: /window/clock/tick-and-stop (test-window.c:3240-3241): the display tick is a
    // WX_APP_CLOCK_TICK_S-period timer of the injected clock alone; real time does not move it.
    @Test func displayClockFollowsTheInjectedClockOnly() async {
        let h = Host()
        h.startLoaded()
        let ticks = h.displayed.count
        for _ in 0..<50 { await Task.yield() }
        #expect(h.displayed.count == ticks, "no tick without the WxClock advancing")
        await h.warp(seconds: RefreshEngine.clockTickS - 1)
        #expect(h.displayed.count == ticks, "no tick before WX_APP_CLOCK_TICK_S (wx-app.h:155)")
        await h.warp(seconds: 1)
        #expect(h.displayed.count == ticks + 1)
        #expect(h.nowS == h.clock.wallSeconds)
        await h.warp(seconds: 3 * RefreshEngine.clockTickS)
        #expect(h.displayed.count == ticks + 4, "one tick per period")
    }

    // C: /window/refresh/hidden-requests-nothing (test-window.c:1622-1627) and the focus
    // round (wx-app.h:376-392): rounds on becoming visible, on focus and on network return.
    @Test func roundsOnVisibleFocusAndNetworkReturn() async {
        let h = Host()
        h.engine.setPlaces([Host.miami])
        #expect(h.fetchCount == 0, "hidden: no round (wx-app.h:358-360)")
        h.engine.setVisible(true)
        #expect(h.fetchCount == 1, "becoming visible starts a round")
        h.finishLast(.failed(Host.network))
        // A failed place is not fresh: the focus round asks it again (wx-app.h:376-392).
        h.engine.windowFocused()
        #expect(h.fetchCount == 2, "focus starts a round")
        h.finishLast(.failed(Host.network))
        h.engine.setOnline(false)
        h.engine.windowFocused()
        #expect(h.fetchCount == 2, "offline: the focus round starts nothing")
        h.engine.setOnline(true)
        #expect(h.fetchCount == 3, "network return starts a round")
    }
}
