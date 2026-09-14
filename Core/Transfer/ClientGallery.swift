import Foundation
import ImageIO

struct GalleryOptions: Codable, Equatable, Sendable {
    var title = ""
    var photographer = ""
    /// Para onde o cliente envia a lista de favoritas.
    var email = ""
    var website = ""
    var longEdge = 2048
    var allowDownload = true
    var watermark = false
}

struct GalleryPhoto: Sendable {
    let url: URL
    let recipe: EditRecipe
    let caption: String
    let keywords: [String]
}

/// Galeria estática para clientes: uma página e as fotos numa só pasta (sem subpastas),
/// pronta a abrir no browser ou a enviar pelos destinos FTP/SFTP/S3/WebDAV. Sem servidor nem custos.
enum ClientGallery {
    struct Item: Codable, Equatable, Sendable {
        var image: String
        var thumb: String
        var width: Int
        var height: Int
        var caption: String
        var keywords: [String]
        var name: String
    }

    /// Textos da página, no idioma da app.
    struct Strings: Codable, Sendable {
        var lang: String
        var search: String
        var favourites: String
        var send: String
        var copy: String
        var copied: String
        var download: String
        var photos: String
        var close: String
        var previous: String
        var next: String
        var empty: String
        var by: String
    }

    static func build(_ photos: [GalleryPhoto], options: GalleryOptions, strings: Strings, exportSettings: ExportSettings,
                      to folder: URL, progress: (Int, Int) -> Void) throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = fm.temporaryDirectory.appendingPathComponent("ppk-gallery-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var large = exportSettings
        large.format = .jpeg
        large.quality = 0.88
        large.sixteenBit = false
        large.colorSpace = .sRGB
        large.resize = true
        large.resizeMode = .longEdge
        large.longEdge = options.longEdge
        large.metadataRule = .copyrightOnly
        large.suffix = ""
        large.watermarkEnabled = options.watermark
        var thumb = large
        thumb.longEdge = 640
        thumb.quality = 0.8
        thumb.watermarkEnabled = false
        thumb.metadataRule = .none
        thumb.outputSharpening = .screen

        var files: [URL] = []
        var items: [Item] = []
        for (index, photo) in photos.enumerated() {
            let number = String(format: "%03d", index + 1)
            let image = try place(ImageRenderer.shared.export(url: photo.url, recipe: photo.recipe, settings: large, to: staging), as: "photo-\(number).jpg", in: folder)
            let preview = try place(ImageRenderer.shared.export(url: photo.url, recipe: photo.recipe, settings: thumb, to: staging), as: "thumb-\(number).jpg", in: folder)
            let info = MetadataReader.basicInfo(for: preview)
            let caption = photo.caption.isEmpty
                ? (MetadataWriter.readMetadata(for: photo.url).flatMap { MetadataReader.xmpString($0, "dc:description") } ?? "")
                : photo.caption
            items.append(Item(image: image.lastPathComponent, thumb: preview.lastPathComponent, width: info.width, height: info.height,
                              caption: caption, keywords: photo.keywords, name: photo.url.lastPathComponent))
            files += [image, preview]
            progress(index + 1, photos.count)
        }
        let page = folder.appendingPathComponent("index.html")
        try Data(html(items: items, options: options, strings: strings).utf8).write(to: page, options: .atomic)
        return files + [page]
    }

    private static func place(_ file: URL, as name: String, in folder: URL) throws -> URL {
        let target = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func html(items: [Item], options: GalleryOptions, strings: Strings) -> String {
        struct Payload: Encodable {
            let items: [Item]
            let strings: Strings
            let title: String
            let email: String
            let allowDownload: Bool
        }
        let payload = Payload(items: items, strings: strings, title: options.title, email: options.email, allowDownload: options.allowDownload)
        // "<" escapado: nenhuma legenda consegue fechar o bloco de dados.
        let data = ((try? JSONEncoder().encode(payload)).map { String(decoding: $0, as: UTF8.self) } ?? "{}")
            .replacingOccurrences(of: "<", with: "\\u003c")
        let title = escape(options.title.isEmpty ? strings.photos : options.title)
        let byline = options.photographer.isEmpty ? "" : "<p class=\"by\">\(escape(strings.by)) \(escape(options.photographer)) · \(items.count) \(escape(strings.photos))</p>"
        var site = ""
        if !options.website.isEmpty {
            let link = options.website.hasPrefix("http://") || options.website.hasPrefix("https://") ? options.website : "https://" + options.website
            site = "<a href=\"\(escape(link))\" rel=\"noopener\">\(escape(options.website))</a>"
        }
        return #"""
        <!doctype html>
        <html lang="\#(escape(strings.lang))">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\#(title)</title>
        <style>
        :root{--bg:#0A0A0F;--panel:#15151C;--line:#2A2A33;--text:#F5F5F0;--muted:#A1A1AA;--accent:#D97706;--accent2:#F59E0B}
        *{box-sizing:border-box}
        body{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
        header{padding:56px 24px 20px;text-align:center}
        h1{margin:0;font-size:clamp(28px,5vw,52px);letter-spacing:-.02em;font-weight:700}
        .by{margin:8px 0 0;color:var(--muted)}
        .bar{position:sticky;top:0;z-index:5;display:flex;flex-wrap:wrap;gap:8px;justify-content:center;padding:12px 16px;background:rgba(10,10,15,.85);backdrop-filter:blur(12px);-webkit-backdrop-filter:blur(12px)}
        .bar input{flex:1 1 220px;max-width:360px;padding:9px 16px;border-radius:999px;border:1px solid var(--line);background:var(--panel);color:var(--text);font:inherit}
        .bar button{padding:9px 16px;border-radius:999px;border:1px solid var(--line);background:var(--panel);color:var(--text);font:inherit;cursor:pointer}
        .bar button.on{background:var(--accent);border-color:var(--accent);color:#fff}
        main{columns:4 280px;column-gap:12px;padding:12px 16px 48px;max-width:1800px;margin:0 auto}
        figure{position:relative;margin:0 0 12px;break-inside:avoid;border-radius:10px;overflow:hidden;background:var(--panel);cursor:zoom-in}
        figure img{display:block;width:100%;height:auto;transition:transform .5s ease}
        figure:hover img{transform:scale(1.03)}
        .heart{position:absolute;top:8px;right:8px;width:38px;height:38px;border:0;border-radius:50%;background:rgba(0,0,0,.45);color:#fff;font-size:18px;cursor:pointer}
        .heart.on{background:var(--accent)}
        .empty{text-align:center;color:var(--muted);padding:48px}
        #box{position:fixed;inset:0;display:none;align-items:center;justify-content:center;flex-direction:column;background:rgba(5,5,8,.96);z-index:10;padding:16px}
        #box.open{display:flex}
        #box img{max-width:94vw;max-height:78vh;border-radius:6px}
        #cap{color:var(--muted);margin:12px 16px;text-align:center}
        .tools{display:flex;gap:8px;flex-wrap:wrap;justify-content:center}
        .tools button,.tools a{padding:8px 16px;border-radius:999px;border:1px solid #33333F;background:var(--panel);color:var(--text);text-decoration:none;font:inherit;cursor:pointer}
        footer{text-align:center;color:var(--muted);padding:24px;font-size:13px}
        footer a{color:var(--accent2)}
        </style>
        </head>
        <body>
        <header><h1>\#(title)</h1>\#(byline)</header>
        <div class="bar"><input id="q" type="search"><button id="fav" type="button"></button><button id="send" type="button"></button><button id="copy" type="button"></button></div>
        <main id="grid"></main>
        <div id="box" role="dialog" aria-modal="true"><img id="big" alt=""><p id="cap"></p><div class="tools"><button id="prev" type="button"></button><button id="like" type="button"></button><a id="dl" download></a><button id="next" type="button"></button><button id="close" type="button"></button></div></div>
        <footer>\#(site)</footer>
        <script id="data" type="application/json">\#(data)</script>
        <script>
        const d=JSON.parse(document.getElementById('data').textContent);
        const s=d.strings;const key='ppk-favourites-'+location.pathname;
        const $=id=>document.getElementById(id);
        let favs=new Set();try{favs=new Set(JSON.parse(localStorage.getItem(key)||'[]'))}catch(e){}
        let onlyFavs=false,shown=[],current=0;
        $('q').placeholder=s.search;$('send').textContent=s.send;$('copy').textContent=s.copy;
        $('prev').textContent='‹ '+s.previous;$('next').textContent=s.next+' ›';$('close').textContent=s.close;$('dl').textContent=s.download;
        if(!d.email)$('send').style.display='none';
        if(!d.allowDownload)$('dl').style.display='none';
        function save(){try{localStorage.setItem(key,JSON.stringify([...favs]))}catch(e){}$('fav').textContent='♥ '+s.favourites+' ('+favs.size+')';$('fav').classList.toggle('on',onlyFavs)}
        function render(){const q=$('q').value.trim().toLowerCase();const grid=$('grid');grid.replaceChildren();
        shown=d.items.filter(i=>(!onlyFavs||favs.has(i.name))&&(!q||(i.name+' '+i.caption+' '+i.keywords.join(' ')).toLowerCase().includes(q)));
        if(!shown.length){const p=document.createElement('p');p.className='empty';p.textContent=s.empty;grid.appendChild(p)}
        shown.forEach((i,n)=>{const f=document.createElement('figure');const img=document.createElement('img');img.src=i.thumb;img.loading='lazy';img.alt=i.caption||i.name;img.width=i.width;img.height=i.height;
        const h=document.createElement('button');h.type='button';h.className='heart'+(favs.has(i.name)?' on':'');h.textContent='♥';h.setAttribute('aria-label',s.favourites);
        h.onclick=e=>{e.stopPropagation();toggle(i.name);h.classList.toggle('on',favs.has(i.name))};
        f.onclick=()=>show(n);f.append(img,h);grid.appendChild(f)});save()}
        function toggle(name){favs.has(name)?favs.delete(name):favs.add(name);save();if(onlyFavs)render()}
        function show(n){if(!shown.length)return;current=(n+shown.length)%shown.length;const i=shown[current];$('big').src=i.image;$('big').alt=i.caption||i.name;$('cap').textContent=i.caption||i.name;$('dl').href=i.image;$('like').textContent=(favs.has(i.name)?'♥ ':'♡ ')+s.favourites;$('box').classList.add('open')}
        function hide(){$('box').classList.remove('open')}
        const list=()=>[...favs].sort().join('\n');
        $('q').oninput=render;$('fav').onclick=()=>{onlyFavs=!onlyFavs;render()};
        $('prev').onclick=()=>show(current-1);$('next').onclick=()=>show(current+1);$('close').onclick=hide;
        $('like').onclick=()=>{if(!shown[current])return;toggle(shown[current].name);show(current)};
        $('box').onclick=e=>{if(e.target.id==='box')hide()};
        document.addEventListener('keydown',e=>{if(!$('box').classList.contains('open'))return;if(e.key==='Escape')hide();if(e.key==='ArrowLeft')show(current-1);if(e.key==='ArrowRight')show(current+1)});
        $('send').onclick=()=>{location.href='mailto:'+d.email+'?subject='+encodeURIComponent(d.title)+'&body='+encodeURIComponent(list())};
        $('copy').onclick=async()=>{try{await navigator.clipboard.writeText(list());$('copy').textContent=s.copied;setTimeout(()=>{$('copy').textContent=s.copy},1500)}catch(e){}};
        render();
        </script>
        </body>
        </html>
        """#
    }
}
