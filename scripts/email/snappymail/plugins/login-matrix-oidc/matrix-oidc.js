// login-matrix-oidc — adds a "Sign in with OIDC" button to the SnappyMail login
// screen that navigates to ./?MatrixOIDC (the plugin's OIDC front-door). Best-effort
// UX only: the SSO link works regardless of whether this button renders, so we never
// auto-redirect (auto-redirect would break sign-out — the Pingvin/Linkding lesson).
(rl => {
	if (!rl) { return; }
	addEventListener('rl-view-model', e => {
		const vm = e.detail;
		if (!vm || 'Login' !== vm.viewModelTemplateID) { return; }
		// the login form mounts a tick after the view-model event; retry briefly.
		let tries = 0;
		const add = () => {
			if (document.getElementById('matrix-oidc-btn')) { return; }
			const form = document.querySelector('#rl-content form') || document.querySelector('form');
			if (!form) { if (++tries < 20) { setTimeout(add, 100); } return; }
			const btn = document.createElement('button');
			btn.id = 'matrix-oidc-btn';
			btn.type = 'button';
			btn.textContent = 'Sign in with OIDC';
			btn.style.cssText = 'display:block;width:100%;margin:0 0 14px;padding:11px;border:0;'
				+ 'border-radius:7px;background:#89b4fa;color:#11111b;font-weight:600;'
				+ 'font-size:.95rem;cursor:pointer';
			btn.addEventListener('click', () => { location.href = './?MatrixOIDC'; });
			form.prepend(btn);
		};
		setTimeout(add, 120);
	});
})(window.rl);
