let _el = null,
  _timer = 0;
export function toast(msg, ms = 1600) {
  if (!_el) {
    _el = document.createElement("div");
    _el.className = "toast";
    _el.setAttribute("role", "status");
    _el.setAttribute("aria-live", "polite");
    document.body.appendChild(_el);
  }
  _el.textContent = msg;
  _el.classList.add("show");
  clearTimeout(_timer);
  _timer = setTimeout(() => _el.classList.remove("show"), ms);
}
