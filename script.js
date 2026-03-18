const navbar = document.querySelector("#mainNav");
const revealItems = document.querySelectorAll(".reveal");
const yearTarget = document.querySelector("#year");
const navbarCollapse = document.querySelector("#navbarMenu");
const navLinks = document.querySelectorAll("#navbarMenu .nav-link");
const heroStage = document.querySelector(".hero-stage");
const logRows = document.querySelectorAll(".log-row");

if (yearTarget) {
  yearTarget.textContent = new Date().getFullYear();
}

const updateNavbar = () => {
  if (!navbar) return;
  navbar.classList.toggle("navbar-scrolled", window.scrollY > 16);
};

updateNavbar();
window.addEventListener("scroll", updateNavbar, { passive: true });

if ("IntersectionObserver" in window) {
  const observer = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add("is-visible");
          observer.unobserve(entry.target);
        }
      });
    },
    {
      threshold: 0.18,
      rootMargin: "0px 0px -48px 0px",
    }
  );

  revealItems.forEach((item) => observer.observe(item));
} else {
  revealItems.forEach((item) => item.classList.add("is-visible"));
}

if (navbarCollapse && navLinks.length) {
  navLinks.forEach((link) => {
    link.addEventListener("click", () => {
      const collapseInstance = bootstrap.Collapse.getInstance(navbarCollapse);
      if (collapseInstance) {
        collapseInstance.hide();
      }
    });
  });
}

if (heroStage && window.matchMedia("(pointer:fine)").matches) {
  heroStage.addEventListener("mousemove", (event) => {
    const bounds = heroStage.getBoundingClientRect();
    const x = ((event.clientX - bounds.left) / bounds.width - 0.5) * 10;
    const y = ((event.clientY - bounds.top) / bounds.height - 0.5) * 10;
    heroStage.style.transform = `perspective(1000px) rotateX(${-y}deg) rotateY(${x}deg)`;
  });

  heroStage.addEventListener("mouseleave", () => {
    heroStage.style.transform = "perspective(1000px) rotateX(0deg) rotateY(0deg)";
  });
}

if (logRows.length && !window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
  let activeLogIndex = 0;

  const activateLogRow = () => {
    logRows.forEach((row, index) => {
      row.classList.toggle("is-active", index === activeLogIndex);
    });
    activeLogIndex = (activeLogIndex + 1) % logRows.length;
  };

  activateLogRow();
  window.setInterval(activateLogRow, 1800);
}
