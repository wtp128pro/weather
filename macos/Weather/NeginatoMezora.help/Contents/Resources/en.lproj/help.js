(function() {
    const input = document.getElementById('help-search');
    const resultsBox = document.getElementById('search-results');
    if (!input || !resultsBox || !window.HELP_SEARCH_INDEX) return;

    input.addEventListener('input', function() {
        const q = input.value.trim().toLowerCase();
        resultsBox.replaceChildren();
        if (q.length < 2) {
            resultsBox.classList.remove('visible');
            return;
        }
        const hits = window.HELP_SEARCH_INDEX.filter(item =>
            item.title.toLowerCase().includes(q) || item.body.toLowerCase().includes(q)
        );
        if (hits.length === 0) {
            const none = document.createElement('div');
            none.className = 'search-hit';
            none.textContent = 'No matching topics found.';
            resultsBox.appendChild(none);
        } else {
            hits.forEach(hit => {
                const a = document.createElement('a');
                a.className = 'search-hit';
                a.href = hit.href;
                const title = document.createElement('strong');
                title.textContent = hit.title;
                const section = document.createElement('span');
                section.textContent = hit.section;
                a.append(title, section);
                resultsBox.appendChild(a);
            });
        }
        resultsBox.classList.add('visible');
    });
})();
