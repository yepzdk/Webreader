// Writes the pages the App Store screenshots are taken from.
//
//     swift Scripts/screenshot-pages.swift        # -> build/screenshots/html/
//
// The pages, not the images: capturing is a browser's job and every browser does it
// differently, so this script stops at the thing that has to be right — the app's own
// markup, from the app's own generator, with settings that suit each device. STORE.md
// gives the viewport, the pixel ratio and the two clicks.
//
// Why not the simulator, which would give real device frames: the app can only be steered
// from outside through `webreader://open?url=…`, and iOS puts a confirmation dialog in
// front of a scheme opened by another process — `simctl openurl` raises "Open in
// WebReader?" and `simctl` cannot tap it away. Driving the pages directly is the honest
// alternative: same markup, same CSS, same font stack, same WebKit family.
//
// The content is real — an article from arbejderen.dk and headlines from the feed the app
// ships pointed at. A screenshot of lorem ipsum is a screenshot of nothing anybody reads.

import Foundation
import ReaderKit

let out = URL(fileURLWithPath: "build/screenshots/html")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let article = Article(
    title: "Fagligt aktive krævede ansvar fra Lemvig-Müller i Kolding: "
         + "“Der skal være ordentlige forhold”",
    byline: "Lucas William Carn",
    siteName: "Arbejderen",
    content: """
    <p>Et prestigeprojekt for virksomheden Lemvig-Müller i Kolding blev torsdag den 10.
    september mødt af røde faner ved indgangen til byggepladsen. Anledningen var, at
    <a href="https://arbejderen.dk/fagligt/">3F Kolding</a> var mødt op for at demonstrere
    mod, at en af virksomhederne på pladsen ikke har overenskomst.</p>
    <p>I en indkaldelse til demonstrationen har fagforeningen skrevet, at “Lemvig-Müller er
    selv en del af den danske model og nyder godt af de spilleregler og fordele, der er ved
    en overenskomst, derfor undrer det os, at de accepterer, at en udenlandsk virksomhed
    arbejder uden overenskomst.”</p>
    <p>3F Kolding har også dokumenteret problemer med løn- og ansættelsesvilkår blandt
    udenlandske medarbejdere på pladsen og har rejst lønkrav for mere end én million
    kroner.</p>
    <blockquote>Lemvig-Müller kunne jo bare stoppe virksomheden fra at arbejde, indtil de
    underskriver en overenskomst. De kunne hurtigt stoppe den her konflikt, men det har de
    valgt ikke at gøre.</blockquote>
    <h2>Ved siden af hovedbygningen</h2>
    <p>Selve projektet, som omtales som Lemvig-Müllers prestigeprojekt, er et nyt stort
    logistikcenter. Det nye center er placeret lige ved siden af Lemvig-Müllers
    hovedbygning.</p>
    <p>Ifølge Mikael Noer er det også en byggeplads, som på overfladen ser ud til at
    overholde alle reglerne. Han fortæller, at 3F Kolding ikke har opdaget større problemer
    med sikkerhed eller afmærkning på pladsen.</p>
    """)

var history = ReaderHistory()
for (title, url) in [
    ("Musk eskalerer antifagforenings-taktikken og underminerer århundreders hårdt vundne "
     + "arbejderrettigheder", "https://arbejderen.dk/leder/musk-eskalerer"),
    ("Nye EU-regler udgør den største velfærdsudfordring i 100 år",
     "https://arbejderen.dk/fagligt/nye-eu-regler"),
    ("'Manden fra børneværelset': Her er de nye sigtelser",
     "https://ekstrabladet.dk/krimi/manden-fra-boernevaerelset"),
    ("Handala II skal til en grundig reparation – men et nyt skib er på vej mod Gaza",
     "https://arbejderen.dk/indland/handala-ii"),
] {
    history.record(title: title, url: url)
}

// A 13" iPad at the phone's settings is half margin, and 17px on that screen is not what
// anybody reads at arm's length. Each device gets the settings a reader would pick on it.
for (device, size, width) in [("iphone", 17, ReaderSettings.Width.normal),
                              ("ipad", 20, ReaderSettings.Width.wide)] {
    var light = ReaderSettings()
    light.theme = .light
    light.fontSize = size
    light.width = width
    var sepia = light
    sepia.theme = .sepia
    sepia.fontSize = size + 3
    var dark = light
    dark.theme = .dark

    for (name, html) in [
        ("reader-light", ReaderPage.html(article: article, settings: light, history: history,
                                         rating: nil, currentURL: "https://arbejderen.dk/f/x",
                                         platform: .iOS)),
        ("reader-sepia", ReaderPage.html(article: article, settings: sepia, history: history,
                                         rating: nil, currentURL: "https://arbejderen.dk/f/x",
                                         platform: .iOS)),
        ("reader-dark", ReaderPage.html(article: article, settings: dark, history: history,
                                        rating: nil, currentURL: "https://arbejderen.dk/f/x",
                                        platform: .iOS)),
        ("start", StartPage.html(appName: "WebReader", settings: light, history: history,
                                 platform: .iOS)),
    ] {
        let file = out.appendingPathComponent("\(device)-\(name).html")
        try html.write(to: file, atomically: true, encoding: .utf8)
        print("wrote \(file.path)")
    }
}
