const form = document.getElementById("leadForm");
const status = document.getElementById("leadStatus");

function setStatus(message, isError = false) {
  status.textContent = message;
  status.style.color = isError ? "#d93025" : "#188038";
}

form?.addEventListener("submit", async (event) => {
  event.preventDefault();
  const button = form.querySelector("button");
  const formData = new FormData(form);
  button.disabled = true;
  button.textContent = "Joining...";
  setStatus("");

  try {
    const response = await fetch("/api/leads", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        name: formData.get("name"),
        email: formData.get("email"),
        audience: formData.get("audience"),
        goal: formData.get("goal"),
        source: "aws-cert-landing"
      })
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(payload.error || "Signup failed.");
    form.reset();
    setStatus("You're on the pilot list. We will reach out with access.");
  } catch (error) {
    setStatus(error.message || "Something went wrong.", true);
  } finally {
    button.disabled = false;
    button.textContent = "Join pilot";
  }
});
