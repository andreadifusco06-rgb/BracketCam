# BracketCam – installazione (uso personale, Apple ID gratuito)

1. Xcode > File > New > Project > iOS > App. Nome: BracketCam, Interface: SwiftUI, Language: Swift.
2. Elimina i file ContentView.swift e BracketCamApp.swift creati da Xcode e trascina nel progetto i 4 file .swift di questa cartella (spunta "Copy items if needed").
3. Selezione del target BracketCam > tab Info > aggiungi due chiavi:
   - Privacy - Camera Usage Description → "Serve per scattare le foto"
   - Privacy - Photo Library Additions Usage Description → "Serve per salvare le foto"
4. Signing & Capabilities: spunta "Automatically manage signing" e scegli il tuo Personal Team (Apple ID).
5. Sull'iPhone: Impostazioni > Privacy e sicurezza > Modalità sviluppatore (attiva e riavvia).
6. Collega l'iPhone, selezionalo in alto come destinazione.
7. Prima di premere Run: Product > Scheme > Edit Scheme > Run > Build Configuration = Release
   (in Debug la fusione è molto più lenta).
8. Run. Al primo avvio: Impostazioni > Generali > VPN e gestione dispositivo > autorizza il tuo Apple ID.

Note
- Il bracketing funziona solo su iPhone vero, non nel simulatore.
- Esposizioni: -2, 0, +2 EV. Si cambiano in CameraModel.swift (evSteps).
- Usa un treppiede o appoggia il telefono: se si muove, la fusione può avere sfocature.
- Scadenza 7 giorni con Apple ID gratuito: ricollega e premi Run per rinnovare.
