// A core script that reaches into the "linked" interface three ways. The
// class it shares with core (.linked-shared) is not a link, and neither is
// app/interfaces/linked/javascript/linked.js named in a comment.
import Lit from "../../interfaces/linked/javascript/linked";

if (document.body.dataset.preset === "linked") {
  document.querySelectorAll(".linked-card, .linked-shared").forEach(Lit);
}
