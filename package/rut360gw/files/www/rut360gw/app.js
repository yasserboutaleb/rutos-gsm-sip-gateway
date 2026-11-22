"use strict";
// rut360gw web page. Served by RutOS uhttpd under a strict Content-Security-Policy:
// no inline script/style, every router value is rendered with textContent.
// Resource rule: nothing runs on the router unless this page asks; the dashboard refresh
// stops while the browser tab is hidden or another tab of the page is open.
const $ = (id) => document.getElementById(id);
const NULL_SID = "00000000000000000000000000000000";
let sid = sessionStorage.getItem("rut360gw_sid") || "";
let cfg = {};
let current = "dashboard";
let statusTimer = null;
let ussdTimer = null;

// ---------------------------------------------------------------- ubus JSON-RPC
async function rpc(object, method, args) {
	const r = await fetch("/ubus", {
		method: "POST", headers: { "Content-Type": "application/json" },
		body: JSON.stringify({ jsonrpc: "2.0", id: Date.now(), method: "call", params: [sid || NULL_SID, object, method, args || {}] })
	});
	const j = await r.json();
	if (j.error) { if (j.error.code === -32002) { logout(true); } throw new Error(j.error.message || "error"); }
	if (!Array.isArray(j.result) || j.result[0] !== 0) {
		if (j.result && j.result[0] === 6) { logout(true); throw new Error("session expired or permission denied"); }
		throw new Error("call failed (code " + (j.result ? j.result[0] : "?") + ")");
	}
	return j.result[1] || {};
}
async function api(method, args) {
	const res = await rpc("rut360gw", method, args);
	if (res.ok === false) throw new Error(res.error || "error");
	return res;
}
function show(el, text, ok) { el.textContent = text; el.className = "msg show " + (ok ? "ok" : "bad"); }
function hideMsg(el) { el.className = "msg"; el.textContent = ""; }
async function withBusy(btn, fn) { btn.disabled = true; try { await fn(); } finally { btn.disabled = false; } }
function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text !== undefined) e.textContent = text; return e; }
function kv(dl, pairs) {
	dl.replaceChildren();
	for (const [k, v] of pairs) { dl.append(el("dt", "", k), el("dd", "", v || "—")); }
}

// ---------------------------------------------------------------- sign in / out
$("loginForm").addEventListener("submit", async (e) => {
	e.preventDefault();
	try {
		sid = NULL_SID;
		const res = await rpc("session", "login", { username: $("user").value, password: $("pass").value });
		sid = res.ubus_rpc_session;
		sessionStorage.setItem("rut360gw_sid", sid);
		$("pass").value = "";
		await start();
	} catch (err) { sid = ""; show($("loginMsg"), "Sign-in refused: wrong credentials or insufficient rights.", false); }
});
function logout(expired) {
	if (sid && sid !== NULL_SID && !expired) { rpc("session", "destroy", { ubus_rpc_session: sid }).catch(() => {}); }
	sid = ""; sessionStorage.removeItem("rut360gw_sid");
	clearInterval(statusTimer); clearTimeout(ussdTimer);
	$("app").classList.add("hidden"); $("topbar").classList.add("hidden"); $("login").classList.remove("hidden");
	if (expired) show($("loginMsg"), "Session expired: please sign in again.", false);
}
$("logout").addEventListener("click", () => logout(false));

// ---------------------------------------------------------------- tabs
const TABS = ["dashboard", "sms", "ussd", "setup", "settings", "logs"];
function openTab(t) {
	current = t;
	document.querySelectorAll("nav button").forEach((x) => x.classList.toggle("active", x.dataset.tab === t));
	TABS.forEach((x) => $("tab-" + x).classList.toggle("hidden", x !== t));
	if (t === "dashboard") loadStatus();
	if (t === "sms") loadSms();
	if (t === "ussd") loadUssd();
	if (t === "setup" || t === "settings") loadConfig();
	if (t === "logs") loadLogs();
}
document.querySelectorAll("nav button").forEach((b) => b.addEventListener("click", () => openTab(b.dataset.tab)));
document.addEventListener("visibilitychange", () => { if (!document.hidden && current === "dashboard") loadStatus(); });

// ---------------------------------------------------------------- dashboard
function tile(label, value, level) {
	const d = el("div", "tile");
	const v = el("div", "value " + (level || ""));
	if (level) v.appendChild(el("span", "dot"));
	v.appendChild(document.createTextNode(value));
	d.append(el("div", "label", label), v);
	return d;
}
function age(s) { return s < 0 ? "never" : s < 120 ? s + " s ago" : Math.round(s / 60) + " min ago"; }
function trunkText(t) {
	if (!t) return ["unavailable", "bad"];
	const [st, rtt] = t.split(" ");
	if (st === "Avail") return ["reachable (" + Math.round(parseFloat(rtt)) + " ms)", "ok"];
	if (st === "NonQual") return ["checking…", "warn"];
	return ["unreachable", "bad"];
}
async function loadStatus() {
	try {
		const s = await api("status");
		$("version").textContent = "rut360gw " + s.version;
		// runtime (Asterisk) extracted into RAM at each router start: built-in package, or downloaded as a
		// fallback, retried every 2 min without limit
		const starting = s.enabled && !s.asterisk && (s.runtime === "downloading" || s.runtime === "waiting_network" || s.runtime === "low_memory");
		const svc = !s.enabled ? ["off (not activated yet)", "warn"] : s.asterisk ? ["running", "ok"]
			: s.runtime === "waiting_network" ? ["waiting for mobile network (retry every 2 min)", "warn"]
			: s.runtime === "low_memory" ? ["not enough free RAM (retry every 2 min)", "bad"]
			: s.runtime === "downloading" ? ["starting (preparing runtime)…", "warn"]
			: ["stopped", "bad"];
		const simPct = s.sim_total > 0 ? Math.round(100 * s.sim_used / s.sim_total) : -1;
		// gateway off or still starting: what depends on Asterisk is neutral, not red
		const off = (label) => tile(label, starting ? "— (starting)" : "— (gateway off)");
		const idle = !s.enabled || starting;
		const manage = s.manage_rutos !== false;
		// automatic RutOS fix pending: done at activation, right after the runtime download
		const fixPending = manage && idle;
		$("tiles").replaceChildren(
			tile("Gateway", svc[0], svc[1]),
			idle ? off("Modem (gateway)") :
				tile("Modem", s.modem === "Free" ? "ready" : s.modem === "absent" ? "not detected" : s.modem === "NoVoice" ? "no voice: calls refused" : s.modem.toLowerCase(), s.modem === "Free" || s.calls > 0 ? "ok" : s.modem === "Initializing" ? "warn" : "bad"),
			tile("Network", (s.operator || "?") + " — " + (s.technology || "?"), s.technology === "LTE" ? "ok" : "warn"),
			tile("VoLTE", (s.volte || "?").toLowerCase(), s.volte === "Active" ? "ok" : "warn"),
			tile("Mobile data", (s.data || "?").toLowerCase(), s.data === "Connected" ? "ok" : "bad"),
			!s.server ? tile("SIP server", "not used (LAN softphone only)") : idle ? off("SIP server") :
				s.server === "register" ? tile("SIP server", s.registration === "Registered" ? "registered" : (s.registration || "not registered").toLowerCase(), s.registration === "Registered" ? "ok" : "bad")
				: tile("SIP server", ...trunkText(s.trunk)),
			idle ? off("SMS bridge") : tile("SMS bridge", s.smsbridge ? "running" : "stopped", s.smsbridge ? "ok" : "warn"),
			tile("SIM storage", simPct < 0 ? "?" : s.sim_used + " / " + s.sim_total + " SMS", simPct < 0 ? "warn" : simPct < 80 ? "ok" : simPct < 95 ? "warn" : "bad"),
			tile("Incoming calls", s.incoming_blocked ? "blocked by RutOS (" + s.call_utils_action + ")" + (fixPending ? (starting ? " — fixed automatically once started" : " — fixed at activation") : "") : "reach the gateway",
				s.incoming_blocked ? (fixPending ? "warn" : "bad") : "ok"),
			tile("Active calls", String(s.calls)),
			tile("Signal", s.signal || "?"),
			tile("Free RAM", s.ram_free_mb + " MB", s.ram_free_mb > 25 ? "ok" : "warn"),
			tile("Router uptime", s.uptime_s < 3600 ? Math.round(s.uptime_s / 60) + " min" : Math.round(s.uptime_s / 3600) + " h")
		);
		const issues = s.rutos_issues || [];
		// automatic management on and the gateway not running yet: the fix happens by itself right after
		// the runtime download, no need (and no reason) to cut mobile data now -> no red box
		$("cuBox").classList.toggle("hidden", issues.length === 0 || fixPending);
		$("cuText").textContent = issues.join(" · ")
			+ (s.incoming_blocked ? " — callers end up on the operator voicemail (RutOS Call Utilities hang up as soon as an action is set, even “ignore”)." : "")
			+ " The fix adjusts only these settings and keeps the original values (restored on uninstall). Mobile data and VoLTE reconnect for 1-2 minutes.";
		hideMsg($("statusMsg"));
	} catch (err) { show($("statusMsg"), "Status unavailable: " + err.message, false); }
}
$("fixCU").addEventListener("click", (e) => withBusy(e.target, async () => {
	if (!confirm("Adjust the RutOS settings the gateway needs (Call Utilities, e-mail forwarding)? Original values are kept and restored on uninstall. Mobile data and VoLTE reconnect for 1-2 minutes.")) return;
	try { const r = await api("fix_call_utils"); show($("statusMsg"), r.message, true); loadStatus(); }
	catch (err) { show($("statusMsg"), err.message, false); }
}));
$("refresh").addEventListener("click", loadStatus);
$("restart").addEventListener("click", (e) => withBusy(e.target, async () => {
	try { const r = await api("restart"); show($("statusMsg"), r.message + " — status refreshes in 20 s.", true); setTimeout(loadStatus, 20000); }
	catch (err) { show($("statusMsg"), err.message, false); }
}));
$("selfTest").addEventListener("click", (e) => withBusy(e.target, async () => {
	const out = $("selfTestOut");
	try {
		const r = await api("self_test");
		out.textContent = (r.lines || []).join("\n");
		out.classList.remove("hidden");
		show($("statusMsg"), r.passed ? "Self-test passed." : "Self-test found problems: see the FAIL lines below.", !!r.passed);
	} catch (err) { show($("statusMsg"), err.message, false); }
}));

// ---------------------------------------------------------------- SMS
async function loadSms() {
	try {
		const r = await api("sms_list");
		const pct = r.total > 0 ? Math.min(100, Math.round(100 * r.used / r.total)) : 0;
		const bar = $("simBar");
		bar.className = pct < 80 ? "okbg" : pct < 95 ? "warnbg" : "badbg";
		bar.dataset.pct = String(Math.round(pct / 5) * 5);   // width via CSS classes (no inline style: CSP)
		$("simText").textContent = r.used + " of " + r.total + " SMS slots used (" + pct + " %).";
		$("purgeText").textContent = r.purge
			? "Automatic clean-up: an SMS relayed over SIP is deleted from the SIM " + Math.round(r.purge_delay / 60) + " min later. SMS that were not relayed are kept."
			: "Automatic clean-up is off: the SIM keeps every SMS (Settings).";
		$("emailText").textContent = r.email_forward
			? "E-mail forwarding (RutOS): enabled."
			: "E-mail forwarding (RutOS): disabled. To receive SMS by e-mail, configure it in the RutOS web interface: Services › Mobile Utilities › SMS Gateway › SMS Forwarding (To Email).";
		if (r.email_forward && r.email_delete) {
			show($("emailWarn"), "Warning: RutOS forwarding is set to delete SMS after forwarding. SMS may then be deleted before the bridge relays them over SIP. Untick “Delete SMS after forwarding” in RutOS: this page cleans the SIM itself.", false);
		} else { hideMsg($("emailWarn")); }
		const list = $("smsList");
		list.replaceChildren();
		if (!r.messages.length) list.append(el("p", "muted", "No SMS on the SIM."));
		for (const m of r.messages) {
			const card = el("div", "sms");
			const head = el("div", "smshead");
			head.append(el("strong", "", m.sender || "?"), el("span", "muted small", m.date));
			const badge = !m.complete ? ["incomplete (waiting for parts)", "warn"]
				: m.relayed ? ["relayed over SIP", "ok"]
				: m.seen ? ["kept on the SIM (not cleaned automatically)", "warn"] : ["new: being relayed", "warn"];
			head.append(el("span", "badge " + badge[1], badge[0]));
			const del = el("button", "secondary small", "Delete");
			del.addEventListener("click", () => withBusy(del, async () => {
				if (!confirm("Delete this SMS from the SIM?")) return;
				try { await api("sms_delete", { index: String(m.index) }); show($("smsMsg"), "SMS deleted.", true); loadSms(); }
				catch (err) { show($("smsMsg"), err.message, false); }
			}));
			head.append(del);
			card.append(head, el("div", "smstext", m.text));
			list.append(card);
		}
	} catch (err) { show($("smsMsg"), "SMS unavailable: " + err.message, false); }
}
$("smsRefresh").addEventListener("click", loadSms);
$("smsClear").addEventListener("click", (e) => withBusy(e.target, async () => {
	if (!confirm("Delete ALL SMS from the SIM? SMS not yet relayed over SIP will be lost.")) return;
	try { const r = await api("sms_delete", { index: "all" }); show($("smsMsg"), r.deleted + " SMS deleted.", true); loadSms(); }
	catch (err) { show($("smsMsg"), err.message, false); }
}));

// ---------------------------------------------------------------- USSD
function fmtTime(ts) { return new Date(ts * 1000).toLocaleTimeString(); }
async function loadUssd() {
	clearTimeout(ussdTimer);
	try {
		const r = await api("ussd_history");
		const log = $("ussdLog");
		log.replaceChildren();
		if (!r.entries.length) log.append(el("p", "muted", "No USSD exchange yet."));
		for (const e of r.entries) {
			const b = el("div", "bubble " + (e.dir === "out" ? "out" : "in"));
			const h = el("div", "bhead");
			h.append(el("strong", "", e.dir === "out" ? "You" : "Network"), el("span", "muted small",
				fmtTime(e.ts) + (e.source === "linphone" ? " · from a softphone" : "") + (e.status === "1" ? " · waiting for your answer" : "")));
			b.append(h, el("div", "btext", e.text));
			log.append(b);
		}
		log.scrollTop = log.scrollHeight;
		$("ussdState").textContent = !r.enabled ? "USSD is disabled (Settings)."
			: r.pending ? "Waiting for the network…" : r.session_open ? "Menu open: type your answer." : "No open session: send a code such as *600#.";
		$("ussdSend").disabled = r.pending || !r.enabled;
		if (r.pending && current === "ussd") ussdTimer = setTimeout(loadUssd, 2000);
	} catch (err) { show($("ussdMsg"), "USSD unavailable: " + err.message, false); }
}
$("ussdForm").addEventListener("submit", (e) => {
	e.preventDefault();
	withBusy($("ussdSend"), async () => {
		const v = $("ussdInput").value.trim();
		if (!v) return;
		try { await api("ussd_send", { request: v }); $("ussdInput").value = ""; hideMsg($("ussdMsg")); setTimeout(loadUssd, 500); }
		catch (err) { show($("ussdMsg"), err.message, false); }
	});
});
// Clear session (as on the Pi dashboard): ends the session with the operator and erases the history
$("ussdClear").addEventListener("click", (e) => withBusy(e.target, async () => {
	try { await api("ussd_clear"); $("ussdInput").value = ""; hideMsg($("ussdMsg")); loadUssd(); }
	catch (err) { show($("ussdMsg"), err.message, false); }
}));
$("ussdRefresh").addEventListener("click", loadUssd);

// ---------------------------------------------------------------- configuration
function fillCountries(sel, list, cur) {
	sel.replaceChildren(...list.map((c) => { const o = el("option", "", c.toUpperCase()); o.value = c; o.selected = c === cur; return o; }));
}
async function loadConfig() {
	try {
		cfg = await api("get_config");
		const countries = (cfg.countries && cfg.countries.length) ? cfg.countries : ["fr", "dz"];
		fillCountries($("s_country"), countries, cfg.country); fillCountries($("c_country"), countries, cfg.country);
		// Setup: remote SIP server
		$("s_on").checked = !!cfg.server_enabled; $("s_mode").value = cfg.server_mode || "register";
		$("s_host").value = cfg.server_host || ""; $("s_port").value = cfg.server_port || "5060";
		$("s_user").value = cfg.server_username || ""; $("s_pass").value = cfg.server_password || ""; $("s_pass").type = "password";
		$("showSpass").textContent = "Show";
		$("s_ext").value = cfg.server_extension || ""; $("s_addr").value = cfg.server_local_address || "";
		$("s_gsmin").value = cfg.gsm_in || "auto";
		setupView();
		// Settings
		$("c_enabled").checked = !!cfg.enabled; $("c_sms").checked = !!cfg.sms_bridge; $("c_ussd").checked = !!cfg.ussd;
		$("c_purge").checked = !!cfg.sms_purge; $("c_purge_delay").value = String(cfg.sms_purge_delay || 300);
		$("c_ringback").value = cfg.ringback || "network";
		$("c_rutos").checked = cfg.manage_rutos !== false;
		$("c_luser").value = cfg.local_username || ""; $("c_lpass").value = cfg.local_password || ""; $("c_lpass").type = "password";
		$("showLpass").textContent = "Show";
		$("c_ldisable").checked = !cfg.local_password;
		$("c_lpass_hint").textContent = cfg.local_password ? "" : "(empty: LAN client disabled)";
		kv($("lanInfo"), [["SIP server", cfg.lan_ip ? cfg.lan_ip + ":5060 (UDP)" : "router LAN address, port 5060 UDP"], ["Reachable from", "the LAN only"]]);
	} catch (err) { show($("saveMsg"), "Configuration unavailable: " + err.message, false); }
}

// ---------------------------------------------------------------- setup (remote SIP server)
function setupView() {
	const on = $("s_on").checked, reg = $("s_mode").value === "register";
	$("srvBox").classList.toggle("hidden", !on);
	$("regRow").classList.toggle("hidden", !reg); $("regActions").classList.toggle("hidden", !reg);
	$("addrBox").classList.toggle("hidden", reg);
	$("s_host_hint").textContent = reg ? "(host name or IP)" : "(its IP address in the VPN)";
	const ext = $("s_ext").value.trim() || "<extension>";
	kv($("srvHelp"), reg ? [
		["Account for the gateway", ($("s_user").value.trim() || "<username>") + " with the password above, UDP; the gateway registers to it"],
		["Incoming GSM calls", "sent to extension " + ext + "; the caller's number is in the display name and in P-Asserted-Identity"],
		["Calls to the mobile network", "route numbers (national, +international) and *USSD codes to the gateway's account"],
		["SMS", "received SMS arrive as SIP MESSAGE to " + ext + "; a MESSAGE to a number from the gateway's account sends an SMS"]
	] : [
		["Peer", "the gateway at " + ($("s_addr").value.trim() || "<its VPN address>") + ":5060 UDP, identified by its address, no authentication"],
		["Incoming GSM calls", "sent to extension " + ext + " (caller's number in the From user)"],
		["Calls to the mobile network", "route numbers and *USSD codes to the peer"],
		["Security", "only over a VPN: the gateway rejects this server address when it comes from the LAN"]
	]);
}
for (const id of ["s_on", "s_mode", "s_user", "s_ext", "s_addr"]) $(id).addEventListener("input", setupView);
$("showSpass").addEventListener("click", () => {
	const p = $("s_pass"); const hide = p.type === "text";
	p.type = hide ? "password" : "text"; $("showSpass").textContent = hide ? "Show" : "Hide";
});
$("saveSetup").addEventListener("click", (e) => withBusy(e.target, async () => {
	const on = $("s_on").checked;
	const a = { enabled: "1", country: $("s_country").value, gsm_in: $("s_gsmin").value, server_enabled: on ? "1" : "0" };
	if (on) {
		Object.assign(a, { server_mode: $("s_mode").value, server_host: $("s_host").value.trim(), server_port: $("s_port").value.trim(),
			server_extension: $("s_ext").value.trim() });
		if ($("s_mode").value === "register") {
			a.server_username = $("s_user").value.trim();
			if ($("s_pass").value !== cfg.server_password) a.server_password = $("s_pass").value;
		} else a.server_local_address = $("s_addr").value.trim();
	}
	try {
		const r = await api("set_config", a);
		show($("setupMsg"), r.message + " — the gateway restarts (about 20 s); check the Dashboard.", true);
		await loadConfig();
	} catch (err) { show($("setupMsg"), err.message, false); }
}));

// ---------------------------------------------------------------- settings
$("showLpass").addEventListener("click", () => {
	const p = $("c_lpass"); const hide = p.type === "text";
	p.type = hide ? "password" : "text"; $("showLpass").textContent = hide ? "Show" : "Hide";
});
$("regenLocal").addEventListener("click", (e) => withBusy(e.target, async () => {
	if (!confirm("Generate a new LAN SIP password? The gateway restarts (about 20 s) and the LAN softphone must be updated.")) return;
	try {
		const r = await api("regen_secret", { which: "local" });
		$("c_lpass").value = r.password; $("c_lpass").type = "text"; $("showLpass").textContent = "Hide"; $("c_ldisable").checked = false;
		show($("saveMsg"), r.message, true);
	} catch (err) { show($("saveMsg"), err.message, false); }
}));
$("save").addEventListener("click", (e) => withBusy(e.target, async () => {
	const a = {
		enabled: $("c_enabled").checked ? "1" : "0", sms_bridge: $("c_sms").checked ? "1" : "0", ussd: $("c_ussd").checked ? "1" : "0",
		sms_purge: $("c_purge").checked ? "1" : "0", sms_purge_delay: $("c_purge_delay").value.trim(), ringback: $("c_ringback").value, manage_rutos: $("c_rutos").checked ? "1" : "0",
		country: $("c_country").value, local_username: $("c_luser").value.trim()
	};
	if ($("c_ldisable").checked) a.local_disable = "1";
	else if ($("c_lpass").value && $("c_lpass").value !== cfg.local_password) a.local_password = $("c_lpass").value;
	try {
		const r = await api("set_config", a);
		show($("saveMsg"), r.message + " — the gateway restarts (about 20 s).", true);
		await loadConfig();
	} catch (err) { show($("saveMsg"), err.message, false); }
}));

// ---------------------------------------------------------------- logs
// ---------------------------------------------------------------- events (Logs tab)
// The router only returns raw syslog lines (same cost as before); turning them into readable events
// happens here, in the browser. Messages written in French by the gateway scripts are translated.
let evKind = "", evList = [];
const NOISE = /Unable to load config file|ccss.conf|no local system nameservers|canary|set_priority_all|runtime already ready|runtime removed from RAM|FAILED download|download incomplete|mirror skipped|: dry run|: sent to the network/
function dur(s) { s = parseInt(s, 10) || 0; return s < 60 ? s + " s" : Math.floor(s / 60) + " min " + String(s % 60).padStart(2, "0") + " s"; }
function parseLine(l) {
	const m = l.match(/^(?:\d+\s+)?\w{3} (\w{3})\s+(\d+) (\d\d:\d\d):\d\d \d{4} \w+\.(\w+) ([\w.-]+?)(?:\[\d+\])?: (.*)$/);
	return m ? { ts: m[1] + " " + m[2] + " " + m[3], prio: m[4], tag: m[5], msg: m[6] } : null;
}
const CALL_IN = { ANSWER: ["answered", "ok"], NOANSWER: ["missed: nobody answered (caller sent to voicemail)", "warn"],
	CANCEL: ["caller hung up before it was answered", "warn"], BUSY: ["busy, caller sent to voicemail (rejected as busy)", "warn"],
	CHANUNAVAIL: ["SIP destination unreachable (not registered?), caller sent to voicemail (rejected as busy)", "bad"],
	CONGESTION: ["failed (SIP server), caller sent to voicemail (rejected as busy)", "bad"] };
const CALL_OUT = { ANSWER: ["answered", "ok"], NOANSWER: ["no answer", "warn"], CANCEL: ["cancelled before answer", ""],
	BUSY: ["busy", "warn"], CHANUNAVAIL: ["modem unavailable", "bad"], CONGESTION: ["refused by the mobile network", "bad"] };
const RUTOS_NAMES = { call_utils: "Call Utilities", sms_gateway: "e-mail forwarding", rut_fota: "RutOS update check off", dfota: "modem update notice off" };
function toEvent(p) {
	const t = p.msg; let m;
	if (NOISE.test(t)) return null;
	if (p.tag === "rut360gw-call" && (m = t.match(/^(in|out) (\S+) (\w+) ?(\d*)$/))) {
		const [txt, lvl] = (m[1] === "in" ? CALL_IN : CALL_OUT)[m[3]] || [m[3].toLowerCase(), ""];
		return { kind: "call", level: lvl, text: (m[1] === "in" ? "Incoming call from " : "Outgoing call to ") + m[2].replace("...", "…") + ": " + txt + (m[3] === "ANSWER" ? ", " + dur(m[4]) : "") };
	}
	if (p.tag === "rut360gw-sms") {
		if ((m = t.match(/^SMS sent to (\S+) \((\d+) chars\)/))) return { kind: "sms", level: "ok", text: "SMS sent to " + m[1] + " (" + m[2] + " characters)" };
		if (/^SMS index \d+ relayed to SIP/.test(t)) return { kind: "sms", level: "ok", text: "SMS received and relayed as a SIP message" };
		if (/ given up after /.test(t)) return { kind: "sms", level: "bad", text: "SMS received but could not be relayed (kept on the SIM)" };
		if (/removed from the SIM \(relayed\)/.test(t)) return { kind: "sms", level: "", text: "Relayed SMS removed from the SIM" };
		if ((m = t.match(/^SMS send failed: (.*)/))) return { kind: "sms", level: "bad", text: "SMS could not be sent (" + m[1] + ")" };
		if (/^send refused/.test(t)) return { kind: "sms", level: "warn", text: "SMS refused: " + (/number/.test(t) ? "invalid number" : "empty text") };
		if ((m = t.match(/^web page: (\d+)\/(\d+) SMS/))) return { kind: "sms", level: "", text: m[1] + " SMS deleted from the SIM (web page)" };
		if ((m = t.match(/^first start: (\d+)/))) return { kind: "system", level: "", text: "SMS bridge first start: " + m[1] + " SMS already on the SIM left untouched" };
		if (/^SMS -> SIP bridge started/.test(t)) return { kind: "system", level: "", text: "SMS bridge started" };
		const ussdSt = (s) => ({ "0": "answer received", "1": "menu received, waiting for your answer", "2": "session closed by the network", "none": "no answer from the network" })[s] || "status " + s;
		if ((m = t.match(/^USSD web (\S+): answer (\S+)/))) return { kind: "ussd", level: m[2] === "none" ? "warn" : "ok", text: "USSD " + m[1] + " (web page): " + ussdSt(m[2]) };
		if ((m = t.match(/^USSD (\S+): answer ([^,]+), relayed to SIP = (\w+)/))) return { kind: "ussd", level: m[3] === "true" ? "ok" : "warn", text: "USSD " + m[1] + " from a softphone: " + ussdSt(m[2]) + (m[3] === "true" ? "" : " (answer not relayed)") };
		if (/^USSD refused/.test(t)) return { kind: "ussd", level: "warn", text: "USSD refused: invalid code" };
	}
	if (p.tag === "rut360gw") {
		if (/^runtime not in RAM yet/.test(t)) return { kind: "system", level: "", text: "Starting: preparing the gateway engine (Asterisk) in the background" };
		if ((m = t.match(/^runtime ready after (\d+)/))) return { kind: "system", level: "ok", text: "Engine ready after " + m[1] + " retries, gateway starting" };
		if ((m = t.match(/^runtime ready \((embedded|downloaded), (\S+) in RAM\)/))) return { kind: "system", level: "ok", text: "Engine ready (" + (m[1] === "embedded" ? "built-in" : "downloaded") + ", " + m[2] + " in RAM)" };
		if (/^embedded runtime (damaged|: extraction failed)/.test(t)) return { kind: "problem", level: "bad", text: "Built-in engine damaged (package rut360gw-runtime): downloaded instead, reinstall the package" };
		if (/^runtime not prepared, not enough RAM/.test(t)) return { kind: "problem", level: "bad", text: "Not enough free RAM to start the engine: retried every 2 min" };
		if (/^runtime unavailable: retrying/.test(t)) return { kind: "problem", level: "warn", text: "No mobile data: engine download retried every 2 min, the gateway starts by itself afterwards" };
		if (/^runtime unavailable$/.test(t)) return { kind: "problem", level: "bad", text: "Engine unavailable: gateway not started" };
		if (/^not enough available RAM/.test(t)) return { kind: "problem", level: "bad", text: "Not enough free RAM to start the engine" };
		if (/^disabled/.test(t)) return { kind: "system", level: "warn", text: "Gateway is off (Settings)" };
		if ((m = t.match(/^WARNING RutOS: (.*?) \(web page/))) return { kind: "problem", level: "warn", text: "RutOS setting: " + m[1] };
		if (/^uninstall/.test(t)) return { kind: "system", level: "", text: "Package removed: original settings restored" };
		if (/^invalid configuration/.test(t)) return { kind: "problem", level: "bad", text: "Invalid settings: gateway not started" };
		if ((m = t.match(/^safety net: (.*?) for \d+ min, no call possible/))) return { kind: "problem", level: "bad", text: "Modem driver stuck (" + m[1] + "): Asterisk restarted automatically" };
		if (/^safety net: .*no more automatic restart/.test(t)) return { kind: "problem", level: "bad", text: "Modem driver still stuck after 3 automatic restarts: run the Self-test, then restart the gateway" };
	}
	if (p.tag === "rut360gw-config") {
		if ((m = t.match(/^configuration generated \(audio=(\S+) data=(\S+) .*country=(\w+)\)/))) return { kind: "system", level: "ok", text: "Gateway started (modem ports " + m[1].replace("/dev/", "") + " / " + m[2].replace("/dev/", "") + ", country " + m[3] + ")" };
		if (/^configuration refused/.test(t)) return { kind: "problem", level: "bad", text: "Settings refused: nothing was saved" };
		if (/^settings migrated from the vps section/.test(t)) return { kind: "system", level: "", text: "Settings of the previous version kept: remote SIP server as a trusted peer over a VPN" };
		return { kind: "problem", level: "bad", text: "Settings: " + t };
	}
	if (p.tag === "rut360gw-fw") {
		if ((m = t.match(/^LAN rules updated: (.*)/))) return { kind: "system", level: "", text: "Firewall rules for the LAN updated: " + m[1] };
		if (/^LAN rules removed/.test(t)) return { kind: "system", level: "", text: "Firewall rules for the LAN removed" };
		return { kind: "problem", level: "warn", text: "Firewall: " + t };
	}
	if (p.tag === "rut360gw-rutos") {
		if ((m = t.match(/^RutOS aligned for the gateway:(.*?) \(original values/))) return { kind: "system", level: "", text: "RutOS adjusted for the gateway: " + m[1].trim().split(/\s+/).map((k) => RUTOS_NAMES[k] || k).join(", ") + " (original values kept)" };
		if (/^reloading mobifd/.test(t)) return { kind: "system", level: "warn", text: "Mobile data and VoLTE reconnecting (1-2 min) to apply the Call Utilities change" };
		if (/^original RutOS settings restored/.test(t)) return { kind: "system", level: "", text: "Original RutOS settings restored" };
	}
	if (p.tag === "rut360gw-runtime") return null;   // duplicates of rut360gw lines written by versions before r46
	if (p.tag === "asterisk") {
		const s = t.replace(/^\w+\[\d+\](?:\[[\w-]+\])?: [\w./-]+:\d+ in \w+: /, "");
		// hangup refused by the modem: the driver hangs the call up again
		if (/\[AT\+(?:QHUP|CHUP|CHLD)[^\]]*\] \S+ Error sending hangup/.test(s)) return { kind: "problem", level: "warn", text: "The modem refused to hang up a call: the gateway hangs it up again if the call goes on" };
		if ((m = s.match(/still listed after hangup, hanging up again \((\d+)\)/))) return { kind: "problem", level: "warn", text: "Call still kept by the modem after hang-up: hung up again (attempt " + m[1] + ")" };
		if (/still listed after \d+ new hangups, giving up/.test(s)) return { kind: "problem", level: "bad", text: "The modem keeps a call it was asked to hang up: the line stays busy until the network ends it" };
		if (/Request to call on device which can not make call/.test(s)) return { kind: "problem", level: "warn", text: "Outgoing call refused: the modem was still busy with another call" };
		if ((m = s.match(/outgoing call listed by the modem after (\d+) polls/))) return { kind: "system", level: "", text: "Outgoing call reported late by the modem (about " + m[1] + " s, switch to 3G): call kept" };
		if ((m = s.match(/outgoing call not listed by the modem after (\d+) polls/))) return { kind: "problem", level: "bad", text: "Outgoing call failed: the modem did not report it within " + m[1] + " s" };
		if ((m = s.match(/unknown call idx:\d+ \((\w+)\) listed by the modem, hanging up \((\d+)\)/))) return { kind: "problem", level: "warn", text: "Call unknown to the gateway found on the modem (" + m[1].toLowerCase() + "): hung up" + (m[2] === "1" ? "" : " again (attempt " + m[2] + ")") };
		if (/Dial answered after its call was released/.test(s)) return { kind: "problem", level: "warn", text: "Cancelled call dialled anyway by the modem: hung up" };
		if (/Cannot enable audio on serial port|Cannot enable UAC/.test(s)) return { kind: "problem", level: "bad", text: "The modem refused to enable voice (a call was in progress?): calls refused until it is enabled again" };
		if (/Voice not enabled: enabling it again/.test(s)) return { kind: "problem", level: "warn", text: "Enabling voice on the modem again" };
		return { kind: "problem", level: p.prio === "err" ? "bad" : "warn", text: "Asterisk: " + s };
	}
	return { kind: p.prio === "err" || p.prio === "warn" ? "problem" : "system", level: p.prio === "err" ? "bad" : p.prio === "warn" ? "warn" : "", text: t };
}
function renderEvents() {
	const box = $("events");
	box.replaceChildren();
	const shown = evList.filter((e) => !evKind || e.kind === evKind || (evKind === "problem" && (e.level === "bad" || e.level === "warn")));
	if (!shown.length) { box.append(el("p", "muted", evList.length ? "No event of this kind in the current log." : "No event yet.")); return; }
	for (const e of shown) {
		const row = el("div", "ev");
		row.append(el("span", "evtime muted small", e.ts), el("span", "evkind " + e.kind, e.kind === "system" ? "gateway" : e.kind),
			el("span", "evtext " + (e.level || ""), e.text));
		box.append(row);
	}
}
async function loadLogs() {
	try {
		const r = await api("logs");
		const lines = r.lines || [];
		$("logs").textContent = lines.join("\n") || "(empty)";
		evList = [];
		for (const l of lines) {
			const p = parseLine(l);
			const e = p && toEvent(p);
			if (e) { e.ts = p.ts; evList.push(e); }
		}
		evList.reverse();
		renderEvents();
	} catch (err) { $("events").replaceChildren(el("p", "bad", "Log unavailable: " + err.message)); }
}
$("refreshLogs").addEventListener("click", loadLogs);
$("rawToggle").addEventListener("click", (e) => {
	const raw = $("logs").classList.toggle("hidden");
	e.target.textContent = raw ? "Show raw log" : "Hide raw log";
});
document.querySelectorAll("#evFilters button").forEach((b) => b.addEventListener("click", () => {
	document.querySelectorAll("#evFilters button").forEach((x) => x.classList.toggle("active", x === b));
	evKind = b.dataset.kind; renderEvents();
}));

// ---------------------------------------------------------------- start
async function start() {
	$("login").classList.add("hidden"); $("app").classList.remove("hidden"); $("topbar").classList.remove("hidden");
	openTab("dashboard");
	clearInterval(statusTimer);
	statusTimer = setInterval(() => { if (!document.hidden && current === "dashboard") loadStatus(); }, 30000);   // ≈ 0.9 s CPU per call on the RUT360
}
if (sid) { start().catch(() => logout(true)); }
