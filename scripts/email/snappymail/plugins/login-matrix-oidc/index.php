<?php

/**
 * login-matrix-oidc — Matrix SSO login for the pocket-homeserver webmail.
 *
 * SnappyMail has no generic standalone OIDC login, and the Maddy mailbox has no
 * server-side OAUTHBEARER. So this plugin uses OIDC purely as the FRONT DOOR: it
 * does the authorization-code dance against the matrix-auth-gw OIDC IdP, and the
 * gateway returns (over a loopback, client-secret-gated token exchange) the
 * user's mailbox address + a SERVER-MANAGED per-user IMAP password the user
 * never sees. The plugin then performs a NORMAL SnappyMail login with that
 * email + password (Maddy verifies it via its pass_table). No
 * token-as-IMAP-credential, no XOAUTH2 — just the standard PLAIN/LOGIN that
 * Maddy already supports.
 *
 * Flow (all on ?MatrixOIDC, registered via addPartHook):
 *   1. no `code`  -> set a state cookie, 302 to the gateway authorize endpoint
 *                    (public, reached via the auth gateway's /authgw/* edge).
 *   2. `code`     -> verify state, POST code+client_secret to the gateway token
 *                    endpoint (LOOPBACK), read {email, imap_password},
 *                    LoginProcess(email, imap_password), 302 to './'.
 *
 * Class name MUST be LoginMatrixOidcPlugin (SnappyMail's
 * Manager::convertPluginFolderNameToClassName maps "login-matrix-oidc" ->
 * "LoginMatrixOidcPlugin"). RE-APPLY ON UPGRADE.
 *
 * GENERALIZED for pocket-homeserver: every operator-specific value (the
 * authorize/token/redirect URLs, the client_id, the welcome From, the welcome
 * service-card links) is substituted at install time by
 * scripts/steps/86-install-webmail.sh from .env — the __TOKENS__ below are
 * replaced before this file is deployed into the userland. Secrets are NEVER
 * embedded: the client secret is read at runtime from a 0600 file the install
 * step writes (see clientSecret() / SECRET_FILE).
 */
class LoginMatrixOidcPlugin extends \RainLoop\Plugins\AbstractPlugin
{
	const
		NAME        = 'Login Matrix OIDC',
		AUTHOR      = 'pocket-homeserver',
		VERSION     = '1.1',
		RELEASE     = '2026-06-19',
		REQUIRED    = '2.36.1',
		CATEGORY    = 'Login',
		LICENSE     = 'MIT',
		DESCRIPTION = 'Matrix SSO login (OIDC front-door + server-managed per-user IMAP password).';

	// Stable endpoints, substituted at install time from .env. `authorize` is
	// PUBLIC (the browser hits it via the auth gateway's public /authgw/* edge);
	// `token` is LOOPBACK (PHP -> gateway directly, no Caddy); redirect_uri is
	// this plugin's own ?MatrixOIDC route (must match the gateway's
	// OIDC_REDIRECT_URIS allowlist). client_secret is read from a 0600 file
	// written by the install step (the SAME secret the gateway holds for
	// client_id "__OIDC_CLIENT_ID__").
	const
		AUTHORIZE_URL = '__OIDC_AUTHORIZE_URL__',
		TOKEN_URL     = '__OIDC_TOKEN_URL__',
		REDIRECT_URI  = '__OIDC_REDIRECT_URI__',
		CLIENT_ID     = '__OIDC_CLIENT_ID__',
		SECRET_FILE   = '/opt/snappymail-data/matrix-oidc-secret',
		STATE_COOKIE  = 'matrix_oidc_state',
		// JIT onboarding: php-fpm runs as root INSIDE the same userland as Maddy,
		// so the plugin can run the Maddy CLI directly (no nested spawn) to
		// create-on-first-login. These paths are the in-userland Maddy install
		// (the email subsystem); substituted at install time.
		MADDY_DIR     = '__MADDY_DIR__',
		MADDY_CONFIG  = '__MADDY_CONFIG__',
		// First-login welcome email, auto-delivered to a NEW member's INBOX
		// (locally via `maddy imap-msgs add` — no relay). Template sits next to
		// this file.  Update welcome.html's service cards whenever a service is
		// added/removed.
		WELCOME_TPL   = 'welcome.html',
		WELCOME_FROM  = '__WELCOME_FROM__',
		// Per-user "already welcomed" markers — decouples the welcome from the
		// mailbox CREATE event so a user provisioned before this feature (or one
		// whose first inject failed) still gets exactly one welcome on a later
		// login. php-fpm (root) writes these; they persist on the data volume.
		WELCOME_MARK_DIR = '/opt/snappymail-data/welcomed';

	public function Init() : void
	{
		$this->addPartHook('MatrixOIDC', 'ServiceMatrixOIDC');
		// NOTE: SnappyMail serves matrix-oidc.js inside a single combined
		// "PluginsLink" bundle whose URL etag = md5(APP_VERSION | <class>@VERSION
		// | js/css paths) — it does NOT depend on the JS file's content or mtime.
		// So editing matrix-oidc.js WITHOUT bumping VERSION leaves the bundle URL
		// unchanged and browsers keep serving the cached old bundle. ALWAYS bump
		// VERSION above when matrix-oidc.js changes (that's the only thing that
		// busts the browser cache).
		$this->addJs('matrix-oidc.js');
	}

	// ── SECURITY-CRITICAL (reviewer writes/verifies) ─────────────────────────
	// Read the OIDC client secret from the 0600 file the install step wrote (the
	// SAME secret the gateway holds for this client). Returning the empty string
	// makes ServiceMatrixOIDC fail closed (redirect to ?MatrixOIDCError=config).
	private function clientSecret() : string
	{
		// Read the 0600 secret the install step wrote (the SAME value the gateway
		// holds for this client). An unreadable/empty file yields '' -> the caller
		// fails closed (redirects to ?MatrixOIDCError=config), never running a
		// partial OIDC flow with an empty client_secret. Never logged, never echoed.
		return \is_readable(static::SECRET_FILE)
			? \trim((string)\file_get_contents(static::SECRET_FILE)) : '';
	}

	public function ServiceMatrixOIDC() : bool
	{
		$oActions = \RainLoop\Api::Actions();
		$oActions->Http()->ServerNoCache();

		$sSecret = $this->clientSecret();
		if (!$sSecret) {
			$oActions->Logger()->Write('login-matrix-oidc: no client secret at '.static::SECRET_FILE, \LOG_ERR, 'MatrixOIDC');
			\MailSo\Base\Http::Location('./?MatrixOIDCError=config');
			return true;
		}

		// ---- step 2: callback (authorization code present) ----
		// NOTE: MailSo\Base\Http has no HasQuery/GetQuery — read $_GET.
		if (isset($_GET['code'])) {
			$sCode  = (string) ($_GET['code'] ?? '');
			$sState = (string) ($_GET['state'] ?? '');
			$sCookie = isset($_COOKIE[static::STATE_COOKIE]) ? (string) $_COOKIE[static::STATE_COOKIE] : '';
			// one-shot: clear the state cookie regardless of outcome
			\setcookie(static::STATE_COOKIE, '', \time() - 3600, '/', '', true, true);
			if (!$sState || !$sCookie || !\hash_equals($sCookie, $sState)) {
				$oActions->Logger()->Write('login-matrix-oidc: state mismatch on callback', \LOG_WARNING, 'MatrixOIDC');
				\MailSo\Base\Http::Location('./?MatrixOIDCError=state');
				return true;
			}
			$aTok = $this->tokenExchange($sCode, $sSecret);
			$sEmail = isset($aTok['email']) ? \trim((string) $aTok['email']) : '';
			$sPass  = isset($aTok['imap_password']) ? \trim((string) $aTok['imap_password']) : '';
			if ($sEmail && $sPass) {
				if (!$this->loginWithProvision($oActions, $sEmail, $sPass)) {
					\MailSo\Base\Http::Location('./?MatrixOIDCError=login');
					return true;
				}
			} else {
				$oActions->Logger()->Write('login-matrix-oidc: token response missing email/imap_password', \LOG_ERR, 'MatrixOIDC');
				\MailSo\Base\Http::Location('./?MatrixOIDCError=token');
				return true;
			}
			\MailSo\Base\Http::Location('./');
			return true;
		}

		// ---- step 1: begin (no code) -> redirect to the gateway authorize endpoint ----
		$sState = \bin2hex(\random_bytes(16));
		$sNonce = \bin2hex(\random_bytes(16));
		\setcookie(static::STATE_COOKIE, $sState, array(
			'expires'  => \time() + 600,
			'path'     => '/',
			'secure'   => true,
			'httponly' => true,
			'samesite' => 'Lax',
		));
		$sUrl = static::AUTHORIZE_URL . '?' . \http_build_query(array(
			'client_id'     => static::CLIENT_ID,
			'redirect_uri'  => static::REDIRECT_URI,
			'response_type' => 'code',
			'scope'         => 'openid email profile',
			'state'         => $sState,
			'nonce'         => $sNonce,
		));
		\MailSo\Base\Http::Location($sUrl);
		return true;
	}

	// ── SECURITY-CRITICAL (reviewer writes/verifies) ─────────────────────────
	// POST the authorization code + client_secret to the gateway's LOOPBACK token
	// endpoint and return the decoded JSON ({email, imap_password, ...}). The
	// gateway derives the imap_password value as an HMAC over the localpart (see the
	// auth-gw snappymail-client extension in the install step / docs). On any
	// non-200 / non-JSON it MUST return an empty array so the caller fails closed.
	private function tokenExchange(string $sCode, string $sSecret) : array
	{
		// Client-secret-gated authorization_code exchange against the gateway's
		// LOOPBACK token endpoint (TOKEN_URL). The secret travels only over loopback
		// and is never logged. ANY error path (non-200, empty body, non-JSON)
		// returns array() so the caller fails closed — never a partial identity.
		$sBody = \http_build_query(array(
			'grant_type'    => 'authorization_code',
			'code'          => $sCode,
			'redirect_uri'  => static::REDIRECT_URI,
			'client_id'     => static::CLIENT_ID,
			'client_secret' => $sSecret,
		));
		$rCurl = \curl_init(static::TOKEN_URL);
		\curl_setopt_array($rCurl, array(
			CURLOPT_POST           => true,
			CURLOPT_POSTFIELDS     => $sBody,
			CURLOPT_RETURNTRANSFER => true,
			CURLOPT_TIMEOUT        => 15,
			CURLOPT_HTTPHEADER     => array('Content-Type: application/x-www-form-urlencoded', 'Accept: application/json'),
		));
		$sResp = \curl_exec($rCurl);
		$iHttp = (int) \curl_getinfo($rCurl, CURLINFO_HTTP_CODE);
		\curl_close($rCurl);
		if (200 !== $iHttp || !$sResp) {
			return array();
		}
		$aJson = \json_decode($sResp, true);
		return \is_array($aJson) ? $aJson : array();
	}

	/**
	 * Log the user into Maddy IMAP. If the FIRST attempt fails because the mailbox
	 * isn't provisioned yet, JIT-create it (Maddy creds + imapsql account) with the
	 * exact server-managed password the gateway just handed us, then retry ONCE.
	 * This gives mail the same create-on-first-login onboarding that other OIDC
	 * apps get for free (their apps own their account store; Maddy doesn't, and has
	 * no create-on-auth — hence we provision here).
	 *
	 * SAFE: we only ever reach this with a Matrix-AUTHENTICATED identity — $sEmail
	 * and $sPass came from the gateway's client-secret-gated /token exchange over
	 * loopback, so we never provision attacker-controlled input. Returns true iff
	 * login succeeded.
	 */
	private function loginWithProvision(\RainLoop\Actions $oActions, string $sEmail, string $sPass) : bool
	{
		// $sPass is wrapped in SensitiveString so SnappyMail never logs it. On a
		// first-login failure (mailbox not yet provisioned) we JIT-create it with the
		// server-managed password and retry exactly ONCE; a second failure returns
		// false (no half-authenticated session). Only reachable with a Matrix-
		// authenticated identity (the values came from the gateway's secret-gated
		// /token exchange over loopback), so we never provision attacker input.
		try {
			$oActions->LoginProcess($sEmail, new \SnappyMail\SensitiveString($sPass));
			$this->maybeWelcome($oActions, $sEmail);   // welcome-once, marker-gated
			return true;
		} catch (\Throwable $oEx) {
			$oActions->Logger()->Write('login-matrix-oidc: first login failed for '
				.$sEmail.' — attempting JIT mailbox provision', \LOG_NOTICE, 'MatrixOIDC');
			$this->ensureMailbox($oActions, $sEmail, $sPass);
			try {
				$oActions->LoginProcess($sEmail, new \SnappyMail\SensitiveString($sPass));
				$oActions->Logger()->Write('login-matrix-oidc: JIT provision + login OK for '.$sEmail, \LOG_NOTICE, 'MatrixOIDC');
				$this->maybeWelcome($oActions, $sEmail);
				return true;
			} catch (\Throwable $oEx2) {
				$oActions->Logger()->WriteException($oEx2, \LOG_ERR);
				return false;
			}
		}
	}

	/**
	 * Send the welcome email AT MOST ONCE per mailbox, gated by a persistent
	 * per-user marker (NOT by the create-event). Called on every successful OIDC
	 * login: the marker makes it a no-op after the first confirmed delivery, but it
	 * means a user provisioned before the welcome feature existed — or one whose
	 * first inject failed — still gets exactly one welcome on a later login.
	 * Best-effort and never fatal: if delivery is not confirmed we leave the marker
	 * absent so the next login retries.
	 */
	private function maybeWelcome(\RainLoop\Actions $oActions, string $sEmail) : void
	{
		$sMark = static::WELCOME_MARK_DIR . '/' . \preg_replace('/[^A-Za-z0-9._@-]/', '_', $sEmail);
		if (\is_file($sMark)) {
			return;
		}
		try {
			if ($this->sendWelcome($oActions, $sEmail)) {
				if (!\is_dir(static::WELCOME_MARK_DIR)) { @\mkdir(static::WELCOME_MARK_DIR, 0700, true); }
				@\file_put_contents($sMark, \gmdate('c') . "\n");
			}
		} catch (\Throwable $oExW) {
			$oActions->Logger()->WriteException($oExW, \LOG_WARNING);
		}
	}

	/**
	 * Idempotently create the Maddy credential + imapsql storage account for
	 * $sEmail with password $sPass. php-fpm runs as root in the SAME userland as
	 * Maddy, so the CLI runs directly (no nested spawn) against the live DBs —
	 * creds/imap-acct are safe to run while the server is up. The `... list |
	 * grep -qxF || ... create` guards make a re-login after a transient IMAP error
	 * a no-op. Output (if any) is logged, never surfaced to the browser.
	 */
	private function ensureMailbox(\RainLoop\Actions $oActions, string $sEmail, string $sPass) : bool
	{
		$sE = \escapeshellarg($sEmail);
		$sP = \escapeshellarg($sPass);
		// creds: idempotent. imap-acct: create iff absent, echoing a marker so the
		// caller can welcome ONLY on a genuine first provisioning (not a transient
		// login retry).
		$sCmd =
			'cd '.static::MADDY_DIR.' && export MADDY_CONFIG='.static::MADDY_CONFIG.'; '
			.'{ ./maddy creds list 2>/dev/null | grep -qxF '.$sE.' || ./maddy creds create --password '.$sP.' '.$sE.'; } 2>&1; '
			.'if ./maddy imap-acct list 2>/dev/null | grep -qxF '.$sE.'; then echo __MBX_EXISTS__; '
			.'else ./maddy imap-acct create '.$sE.' 2>&1 && echo __MBX_CREATED__; fi';
		$sOut = \trim((string) @\shell_exec($sCmd));
		if ('' !== $sOut) {
			$oActions->Logger()->Write('login-matrix-oidc: provision output for '.$sEmail.': '.$sOut, \LOG_INFO, 'MatrixOIDC');
		}
		return false !== \strpos($sOut, '__MBX_CREATED__');
	}

	/**
	 * Deliver the one-time welcome email straight into the new member's INBOX.
	 * Built locally and added via `maddy imap-msgs add <email> INBOX` (php-fpm runs
	 * as root in the SAME userland as Maddy — same path ensureMailbox uses), so it
	 * never touches the relay and is waiting the instant they open webmail. Template
	 * = welcome.html beside this file ({{USER}} placeholder). Best-effort: any
	 * failure is logged, never fatal.
	 */
	private function sendWelcome(\RainLoop\Actions $oActions, string $sEmail) : bool
	{
		$sUser = \explode('@', $sEmail)[0];
		$sTpl  = __DIR__ . '/' . static::WELCOME_TPL;
		$sHtml = \is_readable($sTpl) ? (string) \file_get_contents($sTpl) : '';
		if ('' === $sHtml) {
			$oActions->Logger()->Write('login-matrix-oidc: welcome template missing at '.$sTpl, \LOG_WARNING, 'MatrixOIDC');
			return false;
		}
		$sEml = $this->buildWelcomeEml($sEmail, $sUser, \str_replace('{{USER}}', $sUser, $sHtml));
		$sTmp = \sys_get_temp_dir() . '/welcome-' . \bin2hex(\random_bytes(6)) . '.eml';
		if (false === @\file_put_contents($sTmp, $sEml)) {
			$oActions->Logger()->Write('login-matrix-oidc: cannot write welcome tmp '.$sTmp, \LOG_WARNING, 'MatrixOIDC');
			return false;
		}
		// Capture maddy's exit code explicitly (its "TLS is disabled" notice goes to
		// stderr and is NOT a failure) so the caller only marks the user welcomed on
		// a confirmed RC=0.
		$sCmd = 'cd '.static::MADDY_DIR.' && export MADDY_CONFIG='.static::MADDY_CONFIG.'; '
		      .'./maddy imap-msgs add '.\escapeshellarg($sEmail).' INBOX < '.\escapeshellarg($sTmp).' 2>&1; echo "__RC=$?__"';
		$sOut = \trim((string) @\shell_exec($sCmd));
		@\unlink($sTmp);
		$bOk = false !== \strpos($sOut, '__RC=0__');
		$oActions->Logger()->Write('login-matrix-oidc: welcome inject for '.$sEmail.' -> '.($bOk ? 'ok' : ('FAILED: '.$sOut)), $bOk ? \LOG_INFO : \LOG_WARNING, 'MatrixOIDC');
		return $bOk;
	}

	/** Assemble the multipart/alternative welcome message (CRLF, RFC822). */
	private function buildWelcomeEml(string $sEmail, string $sUser, string $sHtml) : string
	{
		$sBoundary = 'phs_' . \bin2hex(\random_bytes(12));
		$sSubject  = '=?UTF-8?B?' . \base64_encode("\xE2\x9C\xA6 Welcome") . '?=';
		$sText =
			"Welcome aboard, {$sUser}!\r\n\r\nYour account is ready. Mailbox: {$sEmail}\r\n\r\n"
			."Sign in to any app with your Matrix username.\r\n\r\n-- the team\r\n";
		$sHtml = \preg_replace("/\r\n|\r|\n/", "\r\n", $sHtml);
		return \implode("\r\n", array(
			'From: ' . static::WELCOME_FROM,
			'To: ' . $sEmail,
			'Subject: ' . $sSubject,
			'Date: ' . \gmdate('D, d M Y H:i:s') . ' +0000',
			'Message-ID: <welcome-' . \bin2hex(\random_bytes(8)) . '@__MAIL_HOST__>',
			'MIME-Version: 1.0',
			'Content-Type: multipart/alternative; boundary="' . $sBoundary . '"',
			'',
			'--' . $sBoundary,
			'Content-Type: text/plain; charset=utf-8',
			'Content-Transfer-Encoding: 8bit',
			'',
			$sText,
			'--' . $sBoundary,
			'Content-Type: text/html; charset=utf-8',
			'Content-Transfer-Encoding: 8bit',
			'',
			$sHtml,
			'--' . $sBoundary . '--',
			'',
		));
	}

	public function configMapping() : array
	{
		return array();
	}
}
