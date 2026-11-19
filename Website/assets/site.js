// Copy buttons on code blocks, and a collapsed docs nav on narrow screens.
// Prompt markers (<span class="prompt">) and shown output (<span class="out">) are not copied.
(function () {
  document.querySelectorAll("pre").forEach(function (pre) {
    var button = document.createElement("button");
    button.type = "button";
    button.className = "copy-btn";
    button.textContent = "Copy";
    button.addEventListener("click", function () {
      var clone = pre.cloneNode(true);
      clone.querySelectorAll(".prompt, .out, .copy-btn").forEach(function (el) { el.remove(); });
      var text = clone.textContent.replace(/\s+$/, "") + "\n";
      navigator.clipboard.writeText(text).then(function () {
        button.textContent = "Copied";
        button.classList.add("done");
        setTimeout(function () { button.textContent = "Copy"; button.classList.remove("done"); }, 1500);
      });
    });
    pre.appendChild(button);
  });

  var nav = document.querySelector(".docs-nav details");
  if (nav && window.matchMedia("(max-width: 900px)").matches) nav.removeAttribute("open");
})();
