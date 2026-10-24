(function() {
    const input = document.getElementById('help-search');
    const resultsBox = document.getElementById('search-results');
    if (!input || !resultsBox || !window.HELP_SEARCH_INDEX) return;

    input.addEventListener('input', function() {
        const q = input.value.trim().toLowerCase();
        resultsBox.innerHTML = '';
        if (q.length < 2) {
            resultsBox.classList.remove('visible');
            return;
        }
        const hits = window.HELP_SEARCH_INDEX.filter(item =>
            item.title.toLowerCase().includes(q) || item.body.toLowerCase().includes(q)
        );
        if (hits.length === 0) {
            resultsBox.innerHTML = '<div class="search-hit">No matching topics found.</div>';
        } else {
            hits.forEach(hit => {
                const a = document.createElement('a');
                a.className = 'search-hit';
                a.href = hit.href;
                a.innerHTML = '<strong>' + hit.title + '</strong><span>' + hit.section + '</span>';
                resultsBox.appendChild(a);
            });
        }
        resultsBox.classList.add('visible');
    });
})();
