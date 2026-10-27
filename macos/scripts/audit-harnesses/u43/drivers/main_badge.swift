// U43 harness H1 (U22-F2): ShellRow.symbolForPlace on real WxPlace values, old vs new.
import Foundation
import WeatherCore

func place(_ name: String, custom: String = "", isCustom: Bool = false, street: String = "") -> WxPlace {
    var p = try! WxPlace(name: name, admin1: "Region", country: "Country", lat: 48.14, lon: 11.58, timezone: "Europe/Berlin")
    p.customName = custom
    p.isCustomLocation = isCustom
    p.streetAddress = street
    return p
}
/// A custom name the user typed or picked (AppModel.addCustomLocation / renamePlace).
func named(_ n: String) -> WxPlace { place("Somewhere", custom: n, isCustom: true) }
/// A custom-flagged place with no custom name, classified by its own name: preset then Clear
/// (AppModel.swift:876), any address-search result (AddressGeocoder.swift:396; AppModel.swift:817).
func unnamed(_ n: String) -> WxPlace { place(n, isCustom: true, street: n) }

let H = "house.fill", B = "briefcase.fill", P = "person.2.fill", G = "graduationcap.fill", D = "dumbbell.fill"
let T = "tag.fill", M = "mappin.and.ellipse"
let cases: [(group: String, label: String, place: WxPlace, want: String?)] = [
    ("keep", "Home", named("Home"), H), ("keep", "Grandma's House", named("Grandma's House"), H),
    ("keep", "Apt 4B", named("Apt 4B"), H), ("keep", "Work", named("Work"), B), ("keep", "Workplace", named("Workplace"), B),
    ("keep", "Office", named("Office"), B), ("keep", "Mom's", named("Mom's"), P), ("keep", "Dad", named("Dad"), P),
    ("keep", "Friends", named("Friends"), P), ("keep", "Family cabin", named("Family cabin"), P),
    ("keep", "School", named("School"), G), ("keep", "College", named("College"), G), ("keep", "Uni", named("Uni"), G),
    ("keep", "University of Miami", named("University of Miami"), G), ("keep", "Gym", named("Gym"), D),
    ("keep", "Fitness", named("Fitness"), D),
    ("preset", "Home", named("Home"), H), ("preset", "Work", named("Work"), B),
    ("preset", "Friend's place", named("Friend's place"), P), ("preset", "Family", named("Family"), P),
    ("preset", "School", named("School"), G), ("preset", "Gym", named("Gym"), D), ("preset", "Vacation", named("Vacation"), T),
    ("legacy", "custom-flagged 'Home', no custom_name", place("Home", isCustom: true), H),
    ("nine", "Moms", named("Moms"), P), ("nine", "Mommy's", named("Mommy's"), P), ("nine", "Daddy's", named("Daddy's"), P),
    ("nine", "Granddad", named("Granddad"), P), ("nine", "Offices", named("Offices"), B),
    ("nine", "Coworking", named("Coworking"), B), ("nine", "Gyms", named("Gyms"), D),
    ("nine", "Preschool", named("Preschool"), G), ("nine", "Homes", named("Homes"), H),
    ("compound", "Highschool", named("Highschool"), G), ("compound", "Homeoffice", named("Homeoffice"), H),
    ("unicode", "Mom\u{2019}s", named("Mom\u{2019}s"), P), ("unicode", "HOME", named("HOME"), H),
    ("unicode", "Apt.4B", named("Apt.4B"), H), ("unicode", "Home\u{00A0}office", named("Home\u{00A0}office"), H),
    ("lose", "Munich (preset then Clear / address-search city)", unnamed("Munich"), M),
    ("lose", "Trinidad", unnamed("Trinidad"), M), ("lose", "Baghdad", unnamed("Baghdad"), M),
    ("lose", "Tunis", unnamed("Tunis"), M), ("lose", "Homestead", unnamed("Homestead"), M),
    ("lose", "Aptos", unnamed("Aptos"), M), ("lose", "Workington", unnamed("Workington"), M),
    ("lose", "Baptist Hospital", unnamed("Baptist Hospital"), M),
    ("lose", "Union Station (225 S Canal St)", unnamed("Union Station (225 S Canal St)"), M),
    ("lose", "custom 'Community garden'", named("Community garden"), T),
    ("lose", "custom 'Miami-Dade'", named("Miami-Dade"), T), ("lose", "custom 'Lighthouse'", named("Lighthouse"), T),
    ("tradeoff", "Home Depot (2455 Paces Ferry Rd)", unnamed("Home Depot (2455 Paces Ferry Rd)"), H),
    ("tradeoff", "Office Depot", unnamed("Office Depot"), B), ("tradeoff", "Family Dollar", unnamed("Family Dollar"), P),
    ("tradeoff", "1200 University Ave", unnamed("1200 University Ave"), G), ("tradeoff", "45 School St", unnamed("45 School St"), G),
    ("plain", "plain city", place("Munich"), nil), ("plain", "street only", place("Munich", street: "Marienplatz 1"), M),
]
var wrong = 0
for c in cases {
    let got = ShellRow.symbolForPlace(c.place)
    let ok = got == c.want
    if !ok { wrong += 1 }
    print("[\(c.group)] \(c.label): got=\(got ?? "nil") want=\(c.want ?? "nil")\(ok ? "" : "  <-- MISMATCH")")
}
print("badge: cases=\(cases.count) mismatches=\(wrong)")
exit(wrong == 0 ? 0 : 1)
