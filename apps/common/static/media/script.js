const isMobile = {
    Android: () => navigator.userAgent.match(/Android/i),
    iOS: () => navigator.userAgent.match(/iPhone|iPad|iPod/i)
};

window.addEventListener('click', clickHandler)

if (isMobile.iOS) {
    for (const btn of document.getElementsByClassName("close-overlay-btn")) {
        btn.addEventListener("touchend", (e) => setTimeout(() => closeOverlay(e), 100))
    }
}

function clickHandler(e) {
    if (e.target.closest('.contact-tab-btn')) {
        e.target.closest('.contact-tab').classList.toggle('active')
    }
}

window.addEventListener('load', () => {
    const googlePlayBtn = document.querySelector('.google-play-btn');
    const appleStoreBtn = document.querySelector('.apple-store-btn');
    const fDroidBtn = document.querySelector('.f-droid-btn');
    if (!googlePlayBtn || !appleStoreBtn || !fDroidBtn) return;


    if (isMobile.Android()) {
        googlePlayBtn.classList.remove('hidden');
        fDroidBtn.classList.remove('hidden');
    }
    else if (isMobile.iOS()) {
        appleStoreBtn.classList.remove('hidden');
    }
    else {
        appleStoreBtn.classList.remove('hidden');
        googlePlayBtn.classList.remove('hidden');
        fDroidBtn.classList.remove('hidden');
    }
})
