import Foundation

extension RedirectResourceLibrary {

    static let bundledResources: [RedirectResource] = [
        RedirectResource(
            name: "1x1.gif",
            mimeType: "image/gif",
            base64: """
            R0lGODlhAQABAIAAAP///////yH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==
            """
        ),
        RedirectResource(
            name: "2x2.png",
            mimeType: "image/png",
            base64: """
            iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAC0lEQVQI12NgQAcAABIAAe+JVKQAAAAASUVORK5CYII=
            """
        ),
        RedirectResource(
            name: "32x32.png",
            mimeType: "image/png",
            base64: """
            iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAGklEQVRYw+3BAQEAAACCIP+vbkhAAQAAAO8GECAAAZf3V9cA
            AAAASUVORK5CYII=
            """
        ),
        RedirectResource(
            name: "3x2.png",
            mimeType: "image/png",
            base64: """
            iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAYAAACddGYaAAAAC0lEQVQI12NgwAUAABoAASRETuUAAAAASUVORK5CYII=
            """
        ),
        RedirectResource(
            name: "adthrive_abd.js",
            mimeType: "text/javascript",
            base64: """
            KCggKSA9PiB7CiAgICBjb25zdCBkID0gbmV3IERhdGUoRGF0ZS5ub3coKSArIDMwMDAwKTsKICAgIGRvY3VtZW50LmNvb2tp
            ZSA9IGBfX2FkYmxvY2tlcj1mYWxzZTsgZXhwaXJlcz0ke2QudG9VVENTdHJpbmcoKX07IHBhdGg9L2A7Cn0pKCk7Cg==
            """
        ),
        RedirectResource(
            name: "amazon_ads.js",
            mimeType: "text/javascript",
            base64: """
            LyoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
            KioqKioqKioKCiAgICB1QmxvY2sgT3JpZ2luIC0gYSBicm93c2VyIGV4dGVuc2lvbiB0byBibG9jayByZXF1ZXN0cy4KICAg
            IENvcHlyaWdodCAoQykgMjAxOS1wcmVzZW50IFJheW1vbmQgSGlsbAoKICAgIFRoaXMgcHJvZ3JhbSBpcyBmcmVlIHNvZnR3
            YXJlOiB5b3UgY2FuIHJlZGlzdHJpYnV0ZSBpdCBhbmQvb3IgbW9kaWZ5CiAgICBpdCB1bmRlciB0aGUgdGVybXMgb2YgdGhl
            IEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGFzIHB1Ymxpc2hlZCBieQogICAgdGhlIEZyZWUgU29mdHdhcmUgRm91bmRh
            dGlvbiwgZWl0aGVyIHZlcnNpb24gMyBvZiB0aGUgTGljZW5zZSwgb3IKICAgIChhdCB5b3VyIG9wdGlvbikgYW55IGxhdGVy
            IHZlcnNpb24uCgogICAgVGhpcyBwcm9ncmFtIGlzIGRpc3RyaWJ1dGVkIGluIHRoZSBob3BlIHRoYXQgaXQgd2lsbCBiZSB1
            c2VmdWwsCiAgICBidXQgV0lUSE9VVCBBTlkgV0FSUkFOVFk7IHdpdGhvdXQgZXZlbiB0aGUgaW1wbGllZCB3YXJyYW50eSBv
            ZgogICAgTUVSQ0hBTlRBQklMSVRZIG9yIEZJVE5FU1MgRk9SIEEgUEFSVElDVUxBUiBQVVJQT1NFLiAgU2VlIHRoZQogICAg
            R05VIEdlbmVyYWwgUHVibGljIExpY2Vuc2UgZm9yIG1vcmUgZGV0YWlscy4KCiAgICBZb3Ugc2hvdWxkIGhhdmUgcmVjZWl2
            ZWQgYSBjb3B5IG9mIHRoZSBHTlUgR2VuZXJhbCBQdWJsaWMgTGljZW5zZQogICAgYWxvbmcgd2l0aCB0aGlzIHByb2dyYW0u
            ICBJZiBub3QsIHNlZSB7aHR0cDovL3d3dy5nbnUub3JnL2xpY2Vuc2VzL30uCgogICAgSG9tZTogaHR0cHM6Ly9naXRodWIu
            Y29tL2dvcmhpbGwvdUJsb2NrCiovCgooZnVuY3Rpb24oKSB7CiAgICAndXNlIHN0cmljdCc7CiAgICBpZiAoIGFtem5hZHMg
            KSB7CiAgICAgICAgcmV0dXJuOwogICAgfQogICAgdmFyIHcgPSB3aW5kb3c7CiAgICB2YXIgbm9vcGZuID0gZnVuY3Rpb24o
            KSB7CiAgICAgICAgOwogICAgfS5iaW5kKCk7CiAgICB2YXIgYW16bmFkcyA9IHsKICAgICAgICBhcHBlbmRTY3JpcHRUYWc6
            IG5vb3BmbiwKICAgICAgICBhcHBlbmRUYXJnZXRpbmdUb0FkU2VydmVyVXJsOiBub29wZm4sCiAgICAgICAgYXBwZW5kVGFy
            Z2V0aW5nVG9RdWVyeVN0cmluZzogbm9vcGZuLAogICAgICAgIGNsZWFyVGFyZ2V0aW5nRnJvbUdQVEFzeW5jOiBub29wZm4s
            CiAgICAgICAgZG9BbGxUYXNrczogbm9vcGZuLAogICAgICAgIGRvR2V0QWRzQXN5bmM6IG5vb3BmbiwKICAgICAgICBkb1Rh
            c2s6IG5vb3BmbiwKICAgICAgICBkZXRlY3RJZnJhbWVBbmRHZXRVUkw6IG5vb3BmbiwKICAgICAgICBnZXRBZHM6IG5vb3Bm
            biwKICAgICAgICBnZXRBZHNBc3luYzogbm9vcGZuLAogICAgICAgIGdldEFkRm9yU2xvdDogbm9vcGZuLAogICAgICAgIGdl
            dEFkc0NhbGxiYWNrOiBub29wZm4sCiAgICAgICAgZ2V0RGlzcGxheUFkczogbm9vcGZuLAogICAgICAgIGdldERpc3BsYXlB
            ZHNBc3luYzogbm9vcGZuLAogICAgICAgIGdldERpc3BsYXlBZHNDYWxsYmFjazogbm9vcGZuLAogICAgICAgIGdldEtleXM6
            IG5vb3BmbiwKICAgICAgICBnZXRSZWZlcnJlclVSTDogbm9vcGZuLAogICAgICAgIGdldFNjcmlwdFNvdXJjZTogbm9vcGZu
            LAogICAgICAgIGdldFRhcmdldGluZzogbm9vcGZuLAogICAgICAgIGdldFRva2Vuczogbm9vcGZuLAogICAgICAgIGdldFZh
            bGlkTWlsbGlzZWNvbmRzOiBub29wZm4sCiAgICAgICAgZ2V0VmlkZW9BZHM6IG5vb3BmbiwKICAgICAgICBnZXRWaWRlb0Fk
            c0FzeW5jOiBub29wZm4sCiAgICAgICAgZ2V0VmlkZW9BZHNDYWxsYmFjazogbm9vcGZuLAogICAgICAgIGhhbmRsZUNhbGxC
            YWNrOiBub29wZm4sCiAgICAgICAgaGFzQWRzOiBub29wZm4sCiAgICAgICAgcmVuZGVyQWQ6IG5vb3BmbiwKICAgICAgICBz
            YXZlQWRzOiBub29wZm4sCiAgICAgICAgc2V0VGFyZ2V0aW5nOiBub29wZm4sCiAgICAgICAgc2V0VGFyZ2V0aW5nRm9yR1BU
            QXN5bmM6IG5vb3BmbiwKICAgICAgICBzZXRUYXJnZXRpbmdGb3JHUFRTeW5jOiBub29wZm4sCiAgICAgICAgdHJ5R2V0QWRz
            QXN5bmM6IG5vb3BmbiwKICAgICAgICB1cGRhdGVBZHM6IG5vb3BmbgogICAgfTsKICAgIHcuYW16bmFkcyA9IGFtem5hZHM7
            CiAgICB3LmFtem5fYWRzID0gdy5hbXpuX2FkcyB8fCBub29wZm47CiAgICB3LmFheF93cml0ZSA9IHcuYWF4X3dyaXRlIHx8
            IG5vb3BmbjsKICAgIHcuYWF4X3JlbmRlcl9hZCA9IHcuYWF4X3JlbmRlcl9hZCB8fCBub29wZm47Cn0pKCk7Cg==
            """
        ),
        RedirectResource(
            name: "amazon_apstag.js",
            mimeType: "text/javascript",
            base64: """
            LyoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
            KioqKioqKioKCiAgICB1QmxvY2sgT3JpZ2luIC0gYSBicm93c2VyIGV4dGVuc2lvbiB0byBibG9jayByZXF1ZXN0cy4KICAg
            IENvcHlyaWdodCAoQykgMjAxOS1wcmVzZW50IFJheW1vbmQgSGlsbAoKICAgIFRoaXMgcHJvZ3JhbSBpcyBmcmVlIHNvZnR3
            YXJlOiB5b3UgY2FuIHJlZGlzdHJpYnV0ZSBpdCBhbmQvb3IgbW9kaWZ5CiAgICBpdCB1bmRlciB0aGUgdGVybXMgb2YgdGhl
            IEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGFzIHB1Ymxpc2hlZCBieQogICAgdGhlIEZyZWUgU29mdHdhcmUgRm91bmRh
            dGlvbiwgZWl0aGVyIHZlcnNpb24gMyBvZiB0aGUgTGljZW5zZSwgb3IKICAgIChhdCB5b3VyIG9wdGlvbikgYW55IGxhdGVy
            IHZlcnNpb24uCgogICAgVGhpcyBwcm9ncmFtIGlzIGRpc3RyaWJ1dGVkIGluIHRoZSBob3BlIHRoYXQgaXQgd2lsbCBiZSB1
            c2VmdWwsCiAgICBidXQgV0lUSE9VVCBBTlkgV0FSUkFOVFk7IHdpdGhvdXQgZXZlbiB0aGUgaW1wbGllZCB3YXJyYW50eSBv
            ZgogICAgTUVSQ0hBTlRBQklMSVRZIG9yIEZJVE5FU1MgRk9SIEEgUEFSVElDVUxBUiBQVVJQT1NFLiAgU2VlIHRoZQogICAg
            R05VIEdlbmVyYWwgUHVibGljIExpY2Vuc2UgZm9yIG1vcmUgZGV0YWlscy4KCiAgICBZb3Ugc2hvdWxkIGhhdmUgcmVjZWl2
            ZWQgYSBjb3B5IG9mIHRoZSBHTlUgR2VuZXJhbCBQdWJsaWMgTGljZW5zZQogICAgYWxvbmcgd2l0aCB0aGlzIHByb2dyYW0u
            ICBJZiBub3QsIHNlZSB7aHR0cDovL3d3dy5nbnUub3JnL2xpY2Vuc2VzL30uCgogICAgSG9tZTogaHR0cHM6Ly9naXRodWIu
            Y29tL2dvcmhpbGwvdUJsb2NrCiovCgovLyBodHRwczovL3d3dy5yZWRkaXQuY29tL3IvdUJsb2NrT3JpZ2luL2NvbW1lbnRz
            L2doanFwaC8KLy8gaHR0cHM6Ly9naXRodWIuY29tL05hbm9NZW93L1F1aWNrUmVwb3J0cy9pc3N1ZXMvMzcxNwovLyBodHRw
            czovL3d3dy5yZWRkaXQuY29tL3IvdUJsb2NrT3JpZ2luL2NvbW1lbnRzL3F5eDdlbi8KCi8vIGh0dHBzOi8vc2VhcmNoZm94
            Lm9yZy9tb3ppbGxhLWNlbnRyYWwvc291cmNlL2Jyb3dzZXIvZXh0ZW5zaW9ucy93ZWJjb21wYXQvc2hpbXMvYXBzdGFnLmpz
            Ci8vICAgSW1wb3J0IHF1ZXVlLXJlbGF0ZWQgaW5pdGlhbGl6YXRpb24gY29kZS4KCihmdW5jdGlvbigpIHsKICAgICd1c2Ug
            c3RyaWN0JzsKICAgIGNvbnN0IHcgPSB3aW5kb3c7CiAgICBjb25zdCBub29wZm4gPSBmdW5jdGlvbigpIHsKICAgICAgICA7
            IC8vIGpzaGludCBpZ25vcmU6bGluZQogICAgfS5iaW5kKCk7CiAgICBjb25zdCBfUSA9IHcuYXBzdGFnICYmIHcuYXBzdGFn
            Ll9RIHx8IFtdOwogICAgY29uc3QgYXBzdGFnID0gewogICAgICAgIF9RLAogICAgICAgIGZldGNoQmlkczogZnVuY3Rpb24o
            YSwgYikgewogICAgICAgICAgICBpZiAoIHR5cGVvZiBiID09PSAnZnVuY3Rpb24nICkgewogICAgICAgICAgICAgICAgYihb
            XSk7CiAgICAgICAgICAgIH0KICAgICAgICB9LAogICAgICAgIGluaXQ6IG5vb3BmbiwKICAgICAgICBzZXREaXNwbGF5Qmlk
            czogbm9vcGZuLAogICAgICAgIHRhcmdldGluZ0tleXM6IG5vb3BmbiwKICAgIH07CiAgICB3LmFwc3RhZyA9IGFwc3RhZzsK
            ICAgIF9RLnB1c2ggPSBmdW5jdGlvbihwcmVmaXgsIGFyZ3MpIHsKICAgICAgICB0cnkgewogICAgICAgICAgICBzd2l0Y2gg
            KHByZWZpeCkgewogICAgICAgICAgICBjYXNlICdmJzoKICAgICAgICAgICAgICAgIGFwc3RhZy5mZXRjaEJpZHMoLi4uYXJn
            cyk7CiAgICAgICAgICAgICAgICBicmVhazsKICAgICAgICAgICAgfQogICAgICAgIH0gY2F0Y2ggKGUpIHsKICAgICAgICAg
            ICAgY29uc29sZS50cmFjZShlKTsKICAgICAgICB9CiAgICB9OwogICAgZm9yICggY29uc3QgY21kIG9mIF9RICkgewogICAg
            ICAgIF9RLnB1c2goY21kKTsKICAgIH0KfSkoKTsK
            """
        ),
        RedirectResource(
            name: "ampproject_v0.js",
            mimeType: "text/javascript",
            base64: """
            LyoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
            KioqKioqKioKCiAgICB1QmxvY2sgT3JpZ2luIC0gYSBicm93c2VyIGV4dGVuc2lvbiB0byBibG9jayByZXF1ZXN0cy4KICAg
            IENvcHlyaWdodCAoQykgMjAxOS1wcmVzZW50IFJheW1vbmQgSGlsbAoKICAgIFRoaXMgcHJvZ3JhbSBpcyBmcmVlIHNvZnR3
            YXJlOiB5b3UgY2FuIHJlZGlzdHJpYnV0ZSBpdCBhbmQvb3IgbW9kaWZ5CiAgICBpdCB1bmRlciB0aGUgdGVybXMgb2YgdGhl
            IEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGFzIHB1Ymxpc2hlZCBieQogICAgdGhlIEZyZWUgU29mdHdhcmUgRm91bmRh
            dGlvbiwgZWl0aGVyIHZlcnNpb24gMyBvZiB0aGUgTGljZW5zZSwgb3IKICAgIChhdCB5b3VyIG9wdGlvbikgYW55IGxhdGVy
            IHZlcnNpb24uCgogICAgVGhpcyBwcm9ncmFtIGlzIGRpc3RyaWJ1dGVkIGluIHRoZSBob3BlIHRoYXQgaXQgd2lsbCBiZSB1
            c2VmdWwsCiAgICBidXQgV0lUSE9VVCBBTlkgV0FSUkFOVFk7IHdpdGhvdXQgZXZlbiB0aGUgaW1wbGllZCB3YXJyYW50eSBv
            ZgogICAgTUVSQ0hBTlRBQklMSVRZIG9yIEZJVE5FU1MgRk9SIEEgUEFSVElDVUxBUiBQVVJQT1NFLiAgU2VlIHRoZQogICAg
            R05VIEdlbmVyYWwgUHVibGljIExpY2Vuc2UgZm9yIG1vcmUgZGV0YWlscy4KCiAgICBZb3Ugc2hvdWxkIGhhdmUgcmVjZWl2
            ZWQgYSBjb3B5IG9mIHRoZSBHTlUgR2VuZXJhbCBQdWJsaWMgTGljZW5zZQogICAgYWxvbmcgd2l0aCB0aGlzIHByb2dyYW0u
            ICBJZiBub3QsIHNlZSB7aHR0cDovL3d3dy5nbnUub3JnL2xpY2Vuc2VzL30uCgogICAgSG9tZTogaHR0cHM6Ly9naXRodWIu
            Y29tL2dvcmhpbGwvdUJsb2NrCiovCgooZnVuY3Rpb24oKSB7CiAgICAndXNlIHN0cmljdCc7CiAgICBjb25zdCBoZWFkID0g
            ZG9jdW1lbnQuaGVhZDsKICAgIGlmICggIWhlYWQgKSB7IHJldHVybjsgfQogICAgY29uc3Qgc3R5bGUgPSBkb2N1bWVudC5j
            cmVhdGVFbGVtZW50KCdzdHlsZScpOwogICAgc3R5bGUudGV4dENvbnRlbnQgPSBbCiAgICAgICAgJ2JvZHkgeycsCiAgICAg
            ICAgJyAgYW5pbWF0aW9uOiBub25lICFpbXBvcnRhbnQ7JywKICAgICAgICAnICBvdmVyZmxvdzogdW5zZXQgIWltcG9ydGFu
            dDsnLAogICAgICAgICd9JwogICAgXS5qb2luKCdcbicpOwogICAgaGVhZC5hcHBlbmRDaGlsZChzdHlsZSk7Cn0pKCk7Cg==
            """
        ),
        RedirectResource(
            name: "chartbeat.js",
            mimeType: "text/javascript",
            base64: """
            LyoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
            KioqKioqKioKCiAgICB1QmxvY2sgT3JpZ2luIC0gYSBicm93c2VyIGV4dGVuc2lvbiB0byBibG9jayByZXF1ZXN0cy4KICAg
            IENvcHlyaWdodCAoQykgMjAxOS1wcmVzZW50IFJheW1vbmQgSGlsbAoKICAgIFRoaXMgcHJvZ3JhbSBpcyBmcmVlIHNvZnR3
            YXJlOiB5b3UgY2FuIHJlZGlzdHJpYnV0ZSBpdCBhbmQvb3IgbW9kaWZ5CiAgICBpdCB1bmRlciB0aGUgdGVybXMgb2YgdGhl
            IEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGFzIHB1Ymxpc2hlZCBieQogICAgdGhlIEZyZWUgU29mdHdhcmUgRm91bmRh
            dGlvbiwgZWl0aGVyIHZlcnNpb24gMyBvZiB0aGUgTGljZW5zZSwgb3IKICAgIChhdCB5b3VyIG9wdGlvbikgYW55IGxhdGVy
            IHZlcnNpb24uCgogICAgVGhpcyBwcm9ncmFtIGlzIGRpc3RyaWJ1dGVkIGluIHRoZSBob3BlIHRoYXQgaXQgd2lsbCBiZSB1
            c2VmdWwsCiAgICBidXQgV0lUSE9VVCBBTlkgV0FSUkFOVFk7IHdpdGhvdXQgZXZlbiB0aGUgaW1wbGllZCB3YXJyYW50eSBv
            ZgogICAgTUVSQ0hBTlRBQklMSVRZIG9yIEZJVE5FU1MgRk9SIEEgUEFSVElDVUxBUiBQVVJQT1NFLiAgU2VlIHRoZQogICAg
            R05VIEdlbmVyYWwgUHVibGljIExpY2Vuc2UgZm9yIG1vcmUgZGV0YWlscy4KCiAgICBZb3Ugc2hvdWxkIGhhdmUgcmVjZWl2
            ZWQgYSBjb3B5IG9mIHRoZSBHTlUgR2VuZXJhbCBQdWJsaWMgTGljZW5zZQogICAgYWxvbmcgd2l0aCB0aGlzIHByb2dyYW0u
            ICBJZiBub3QsIHNlZSB7aHR0cDovL3d3dy5nbnUub3JnL2xpY2Vuc2VzL30uCgogICAgSG9tZTogaHR0cHM6Ly9naXRodWIu
            Y29tL2dvcmhpbGwvdUJsb2NrCiovCgooZnVuY3Rpb24oKSB7CiAgICAndXNlIHN0cmljdCc7CiAgICBjb25zdCBub29wZm4g
            PSBmdW5jdGlvbigpIHsKICAgIH07CiAgICB3aW5kb3cucFNVUEVSRkxZID0gewogICAgICAgIGFjdGl2aXR5OiBub29wZm4s
            CiAgICAgICAgdmlydHVhbFBhZ2U6IG5vb3BmbgogICAgfTsKICAgIGZvciAoIGNvbnN0IGhpZGVyIG9mIGRvY3VtZW50LnF1
            ZXJ5U2VsZWN0b3JBbGwoJ3N0eWxlW2lkXj1jaGFydGJlYXQtZmxpY2tlci1jb250cm9sXScpICkgewogICAgICAgIGhpZGVy
            LnJlbW92ZSgpOwogICAgfQp9KSgpOwo=
            """
        ),
        RedirectResource(
            name: "doubleclick_instream_ad_status.js",
            mimeType: "text/javascript",
            base64: """
            d2luZG93Lmdvb2dsZV9hZF9zdGF0dXMgPSAxOwo=
            """
        ),
        RedirectResource(
            name: "fingerprint2.js",
            mimeType: "text/javascript",
            base64: """
            LyoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
            KioqKioqKioKCiAgICB1QmxvY2sgT3JpZ2luIC0gYSBicm93c2VyIGV4dGVuc2lvbiB0byBibG9jayByZXF1ZXN0cy4KICAg
            IENvcHlyaWdodCAoQykgMjAxNC1wcmVzZW50IFJheW1vbmQgSGlsbAoKICAgIFRoaXMgcHJvZ3JhbSBpcyBmcmVlIHNvZnR3
            YXJlOiB5b3UgY2FuIHJlZGlzdHJpYnV0ZSBpdCBhbmQvb3IgbW9kaWZ5CiAgICBpdCB1bmRlciB0aGUgdGVybXMgb2YgdGhl
            IEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGFzIHB1Ymxpc2hlZCBieQogICAgdGhlIEZyZWUgU29mdHdhcmUgRm91bmRh
            dGlvbiwgZWl0aGVyIHZlcnNpb24gMyBvZiB0aGUgTGljZW5zZSwgb3IKICAgIChhdCB5b3VyIG9wdGlvbikgYW55IGxhdGVy
            IHZlcnNpb24uCgogICAgVGhpcyBwcm9ncmFtIGlzIGRpc3RyaWJ1dGVkIGluIHRoZSBob3BlIHRoYXQgaXQgd2lsbCBiZSB1
            c2VmdWwsCiAgICBidXQgV0lUSE9VVCBBTlkgV0FSUkFOVFk7IHdpdGhvdXQgZXZlbiB0aGUgaW1wbGllZCB3YXJyYW50eSBv
            ZgogICAgTUVSQ0hBTlRBQklMSVRZIG9yIEZJVE5FU1MgRk9SIEEgUEFSVElDVUxBUiBQVVJQT1NFLiAgU2VlIHRoZQogICAg
            R05VIEdlbmVyYWwgUHVibGljIExpY2Vuc2UgZm9yIG1vcmUgZGV0YWlscy4KCiAgICBZb3Ugc2hvdWxkIGhhdmUgcmVjZWl2
            ZWQgYSBjb3B5IG9mIHRoZSBHTlUgR2VuZXJhbCBQdWJsaWMgTGljZW5zZQogICAgYWxvbmcgd2l0aCB0aGlzIHByb2dyYW0u
            ICBJZiBub3QsIHNlZSB7aHR0cDovL3d3dy5nbnUub3JnL2xpY2Vuc2VzL30uCgogICAgSG9tZTogaHR0cHM6Ly9naXRodWIu
            Y29tL2dvcmhpbGwvdUJsb2NrCiovCgovLyBSZWZlcmVuY2U6Ci8vIGh0dHBzOi8vZ2l0aHViLmNvbS9maW5nZXJwcmludGpz
            L2ZpbmdlcnByaW50anMvdHJlZS92MgoKKGZ1bmN0aW9uKCkgewogICAgJ3VzZSBzdHJpY3QnOwogICAgY29uc3QgaGV4MzIg
            PSBsZW4gPT4gewogICAgICAgIHJldHVybiBNYXRoLmZsb29yKE1hdGgucmFuZG9tKCkgKiBOdW1iZXIuTUFYX1NBRkVfSU5U
            RUdFUikKICAgICAgICAgICAgLnRvU3RyaW5nKDE2KQogICAgICAgICAgICAuc2xpY2UoLWxlbikKICAgICAgICAgICAgLnBh
            ZFN0YXJ0KGxlbiwgJzAnKTsKICAgIH07CiAgICBjb25zdCBicm93c2VySWQgPSBgJHtoZXgzMig4KX0ke2hleDMyKDgpfSR7
            aGV4MzIoOCl9JHtoZXgzMig4KX1gOwogICAgY29uc3QgZnAyID0gZnVuY3Rpb24oKXt9OwogICAgZnAyLmdldCA9IGZ1bmN0
            aW9uKG9wdHMsIGNiKSB7CiAgICAgICAgaWYgKCAhY2IgICkgeyBjYiA9IG9wdHM7IH0KICAgICAgICBzZXRUaW1lb3V0KCgg
            KSA9PiB7IGNiKFtdKTsgfSwgMSk7CiAgICB9OwogICAgZnAyLmdldFByb21pc2UgPSBmdW5jdGlvbigpIHsKICAgICAgICBy
            ZXR1cm4gUHJvbWlzZS5yZXNvbHZlKFtdKTsKICAgIH07CiAgICBmcDIuZ2V0VjE4ID0gZnVuY3Rpb24oKSB7CiAgICAgICAg
            cmV0dXJuIGJyb3dzZXJJZDsKICAgIH07CiAgICBmcDIueDY0aGFzaDEyOCA9IGZ1bmN0aW9uKCkgewogICAgICAgIHJldHVy
            biBicm93c2VySWQ7CiAgICB9OwogICAgZnAyLnByb3RvdHlwZSA9IHsKICAgICAgICBnZXQ6IGZ1bmN0aW9uKG9wdHMsIGNi
            KSB7CiAgICAgICAgICAgIGlmICggIWNiICApIHsgY2IgPSBvcHRzOyB9CiAgICAgICAgICAgIHNldFRpbWVvdXQoKCApID0+
            IHsgY2IoYnJvd3NlcklkLCBbXSk7IH0sIDEpOwogICAgICAgIH0sCiAgICB9OwogICAgc2VsZi5GaW5nZXJwcmludDIgPSBz
            ZWxmLkZpbmdlcnByaW50ID0gZnAyOwp9KSgpOwo=
            """
        ),
        RedirectResource(
            name: "fingerprint3.js",
            mimeType: "text/javascript",
            base64: """
            LyoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
            KioqKioqKioKCiAgICB1QmxvY2sgT3JpZ2luIC0gYSBicm93c2VyIGV4dGVuc2lvbiB0byBibG9jayByZXF1ZXN0cy4KICAg
            IENvcHlyaWdodCAoQykgMjAyMi1wcmVzZW50IFJheW1vbmQgSGlsbAoKICAgIFRoaXMgcHJvZ3JhbSBpcyBmcmVlIHNvZnR3
            YXJlOiB5b3UgY2FuIHJlZGlzdHJpYnV0ZSBpdCBhbmQvb3IgbW9kaWZ5CiAgICBpdCB1bmRlciB0aGUgdGVybXMgb2YgdGhl
            IEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGFzIHB1Ymxpc2hlZCBieQogICAgdGhlIEZyZWUgU29mdHdhcmUgRm91bmRh
            dGlvbiwgZWl0aGVyIHZlcnNpb24gMyBvZiB0aGUgTGljZW5zZSwgb3IKICAgIChhdCB5b3VyIG9wdGlvbikgYW55IGxhdGVy
            IHZlcnNpb24uCgogICAgVGhpcyBwcm9ncmFtIGlzIGRpc3RyaWJ1dGVkIGluIHRoZSBob3BlIHRoYXQgaXQgd2lsbCBiZSB1
            c2VmdWwsCiAgICBidXQgV0lUSE9VVCBBTlkgV0FSUkFOVFk7IHdpdGhvdXQgZXZlbiB0aGUgaW1wbGllZCB3YXJyYW50eSBv
            ZgogICAgTUVSQ0hBTlRBQklMSVRZIG9yIEZJVE5FU1MgRk9SIEEgUEFSVElDVUxBUiBQVVJQT1NFLiAgU2VlIHRoZQogICAg
            R05VIEdlbmVyYWwgUHVibGljIExpY2Vuc2UgZm9yIG1vcmUgZGV0YWlscy4KCiAgICBZb3Ugc2hvdWxkIGhhdmUgcmVjZWl2
            ZWQgYSBjb3B5IG9mIHRoZSBHTlUgR2VuZXJhbCBQdWJsaWMgTGljZW5zZQogICAgYWxvbmcgd2l0aCB0aGlzIHByb2dyYW0u
            ICBJZiBub3QsIHNlZSB7aHR0cDovL3d3dy5nbnUub3JnL2xpY2Vuc2VzL30uCgogICAgSG9tZTogaHR0cHM6Ly9naXRodWIu
            Y29tL2dvcmhpbGwvdUJsb2NrCiovCgooZnVuY3Rpb24oKSB7CiAgICAndXNlIHN0cmljdCc7CiAgICBjb25zdCB2aXNpdG9y
            SWQgPSAoKCApID0+IHsKICAgICAgICBsZXQgaWQgPSAnJzsKICAgICAgICBmb3IgKCBsZXQgaSA9IDA7IGkgPCA4OyBpKysg
            KSB7CiAgICAgICAgICAgIGlkICs9IChNYXRoLnJhbmRvbSgpICogMHgxMDAwMCArIDB4MTAwMCB8IDApLnRvU3RyaW5nKDE2
            KS5zbGljZSgtNCk7CiAgICAgICAgfQogICAgICAgIHJldHVybiBpZDsKICAgIH0pKCk7CiAgICBjb25zdCBGaW5nZXJwcmlu
            dEpTID0gY2xhc3MgewogICAgICAgIHN0YXRpYyBoYXNoQ29tcG9uZW50cygpIHsKICAgICAgICAgICAgcmV0dXJuIHZpc2l0
            b3JJZDsKICAgICAgICB9CiAgICAgICAgc3RhdGljIGxvYWQoKSB7CiAgICAgICAgICAgIHJldHVybiBQcm9taXNlLnJlc29s
            dmUobmV3IEZpbmdlcnByaW50SlMoKSk7CiAgICAgICAgfQogICAgICAgIGdldCgpIHsKICAgICAgICAgICAgcmV0dXJuIFBy
            b21pc2UucmVzb2x2ZSh7CiAgICAgICAgICAgICAgICB2aXNpdG9ySWQsCiAgICAgICAgICAgIH0pOwogICAgICAgIH0KICAg
            IH07CiAgICB3aW5kb3cuRmluZ2VycHJpbnRKUyA9IEZpbmdlcnByaW50SlM7Cn0pKCk7Cg==
            """
        ),
        RedirectResource(
            name: "google-analytics_analytics.js",
            mimeType: "text/javascript",
            base64: """
            LyoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
            KioqKioqKioKCiAgICB1QmxvY2sgT3JpZ2luIC0gYSBicm93c2VyIGV4dGVuc2lvbiB0byBibG9jayByZXF1ZXN0cy4KICAg
            IENvcHlyaWdodCAoQykgMjAxOS1wcmVzZW50IFJheW1vbmQgSGlsbAoKICAgIFRoaXMgcHJvZ3JhbSBpcyBmcmVlIHNvZnR3
            YXJlOiB5b3UgY2FuIHJlZGlzdHJpYnV0ZSBpdCBhbmQvb3IgbW9kaWZ5CiAgICBpdCB1bmRlciB0aGUgdGVybXMgb2YgdGhl
            IEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGFzIHB1Ymxpc2hlZCBieQogICAgdGhlIEZyZWUgU29mdHdhcmUgRm91bmRh
            dGlvbiwgZWl0aGVyIHZlcnNpb24gMyBvZiB0aGUgTGljZW5zZSwgb3IKICAgIChhdCB5b3VyIG9wdGlvbikgYW55IGxhdGVy
            IHZlcnNpb24uCgogICAgVGhpcyBwcm9ncmFtIGlzIGRpc3RyaWJ1dGVkIGluIHRoZSBob3BlIHRoYXQgaXQgd2lsbCBiZSB1
            c2VmdWwsCiAgICBidXQgV0lUSE9VVCBBTlkgV0FSUkFOVFk7IHdpdGhvdXQgZXZlbiB0aGUgaW1wbGllZCB3YXJyYW50eSBv
            ZgogICAgTUVSQ0hBTlRBQklMSVRZIG9yIEZJVE5FU1MgRk9SIEEgUEFSVElDVUxBUiBQVVJQT1NFLiAgU2VlIHRoZQogICAg
            R05VIEdlbmVyYWwgUHVibGljIExpY2Vuc2UgZm9yIG1vcmUgZGV0YWlscy4KCiAgICBZb3Ugc2hvdWxkIGhhdmUgcmVjZWl2
            ZWQgYSBjb3B5IG9mIHRoZSBHTlUgR2VuZXJhbCBQdWJsaWMgTGljZW5zZQogICAgYWxvbmcgd2l0aCB0aGlzIHByb2dyYW0u
            ICBJZiBub3QsIHNlZSB7aHR0cDovL3d3dy5nbnUub3JnL2xpY2Vuc2VzL30uCgogICAgSG9tZTogaHR0cHM6Ly9naXRodWIu
            Y29tL2dvcmhpbGwvdUJsb2NrCiovCgooZnVuY3Rpb24oKSB7CiAgICAndXNlIHN0cmljdCc7CiAgICAvLyBodHRwczovL2Rl
            dmVsb3BlcnMuZ29vZ2xlLmNvbS9hbmFseXRpY3MvZGV2Z3VpZGVzL2NvbGxlY3Rpb24vYW5hbHl0aWNzanMvCiAgICBjb25z
            dCBub29wZm4gPSBmdW5jdGlvbigpIHsKICAgIH07CiAgICAvLwogICAgY29uc3QgVHJhY2tlciA9IGZ1bmN0aW9uKCkgewog
            ICAgfTsKICAgIGNvbnN0IHAgPSBUcmFja2VyLnByb3RvdHlwZTsKICAgIHAuZ2V0ID0gbm9vcGZuOwogICAgcC5zZXQgPSBu
            b29wZm47CiAgICBwLnNlbmQgPSBub29wZm47CiAgICAvLwogICAgY29uc3QgdyA9IHdpbmRvdzsKICAgIGNvbnN0IGdhTmFt
            ZSA9IHcuR29vZ2xlQW5hbHl0aWNzT2JqZWN0IHx8ICdnYSc7CiAgICBjb25zdCBnYVF1ZXVlID0gd1tnYU5hbWVdOwogICAg
            Ly8gaHR0cHM6Ly9naXRodWIuY29tL3VCbG9ja09yaWdpbi91QXNzZXRzL3B1bGwvNDExNQogICAgY29uc3QgZ2EgPSBmdW5j
            dGlvbigpIHsKICAgICAgICBjb25zdCBsZW4gPSBhcmd1bWVudHMubGVuZ3RoOwogICAgICAgIGlmICggbGVuID09PSAwICkg
            eyByZXR1cm47IH0KICAgICAgICBjb25zdCBhcmdzID0gQXJyYXkuZnJvbShhcmd1bWVudHMpOwogICAgICAgIGxldCBmbjsK
            ICAgICAgICBsZXQgYSA9IGFyZ3NbbGVuLTFdOwogICAgICAgIGlmICggYSBpbnN0YW5jZW9mIE9iamVjdCAmJiBhLmhpdENh
            bGxiYWNrIGluc3RhbmNlb2YgRnVuY3Rpb24gKSB7CiAgICAgICAgICAgIGZuID0gYS5oaXRDYWxsYmFjazsKICAgICAgICB9
            IGVsc2UgaWYgKCBhIGluc3RhbmNlb2YgRnVuY3Rpb24gKSB7CiAgICAgICAgICAgIGZuID0gKCApID0+IHsgYShnYS5jcmVh
            dGUoKSk7IH07CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgY29uc3QgcG9zID0gYXJncy5pbmRleE9mKCdoaXRDYWxs
            YmFjaycpOwogICAgICAgICAgICBpZiAoIHBvcyAhPT0gLTEgJiYgYXJnc1twb3MrMV0gaW5zdGFuY2VvZiBGdW5jdGlvbiAp
            IHsKICAgICAgICAgICAgICAgIGZuID0gYXJnc1twb3MrMV07CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICAgICAgaWYg
            KCBmbiBpbnN0YW5jZW9mIEZ1bmN0aW9uID09PSBmYWxzZSApIHsgcmV0dXJuOyB9CiAgICAgICAgdHJ5IHsKICAgICAgICAg
            ICAgZm4oKTsKICAgICAgICB9IGNhdGNoIChleCkgewogICAgICAgIH0KICAgIH07CiAgICBnYS5jcmVhdGUgPSBmdW5jdGlv
            bigpIHsKICAgICAgICByZXR1cm4gbmV3IFRyYWNrZXIoKTsKICAgIH07CiAgICBnYS5nZXRCeU5hbWUgPSBmdW5jdGlvbigp
            IHsKICAgICAgICByZXR1cm4gbmV3IFRyYWNrZXIoKTsKICAgIH07CiAgICBnYS5nZXRBbGwgPSBmdW5jdGlvbigpIHsKICAg
            ICAgICByZXR1cm4gW25ldyBUcmFja2VyKCldOwogICAgfTsKICAgIGdhLnJlbW92ZSA9IG5vb3BmbjsKICAgIC8vIGh0dHBz
            Oi8vZ2l0aHViLmNvbS91QmxvY2tPcmlnaW4vdUFzc2V0cy9pc3N1ZXMvMjEwNwogICAgZ2EubG9hZGVkID0gdHJ1ZTsKICAg
            IHdbZ2FOYW1lXSA9IGdhOwogICAgLy8gaHR0cHM6Ly9naXRodWIuY29tL2dvcmhpbGwvdUJsb2NrL2lzc3Vlcy8zMDc1CiAg
            ICBjb25zdCBkbCA9IHcuZGF0YUxheWVyOwogICAgaWYgKCBkbCBpbnN0YW5jZW9mIE9iamVjdCApIHsKICAgICAgICBpZiAo
            IGRsLmhpZGUgaW5zdGFuY2VvZiBPYmplY3QgJiYgdHlwZW9mIGRsLmhpZGUuZW5kID09PSAnZnVuY3Rpb24nICkgewogICAg
            ICAgICAgICBkbC5oaWRlLmVuZCgpOwogICAgICAgICAgICBkbC5oaWRlLmVuZCA9ICgpPT57fTsKICAgICAgICB9CiAgICAg
            ICAgaWYgKCB0eXBlb2YgZGwucHVzaCA9PT0gJ2Z1bmN0aW9uJyApIHsKICAgICAgICAgICAgY29uc3QgZG9DYWxsYmFjayA9
            IGZ1bmN0aW9uKGl0ZW0pIHsKICAgICAgICAgICAgICAgIGlmICggaXRlbSBpbnN0YW5jZW9mIE9iamVjdCA9PT0gZmFsc2Ug
            KSB7IHJldHVybjsgfQogICAgICAgICAgICAgICAgaWYgKCB0eXBlb2YgaXRlbS5ldmVudENhbGxiYWNrICE9PSAnZnVuY3Rp
            b24nICkgeyByZXR1cm47IH0KICAgICAgICAgICAgICAgIHNldFRpbWVvdXQoaXRlbS5ldmVudENhbGxiYWNrLCAxKTsKICAg
            ICAgICAgICAgICAgIGl0ZW0uZXZlbnRDYWxsYmFjayA9ICgpPT57fTsKICAgICAgICAgICAgfTsKICAgICAgICAgICAgZGwu
            cHVzaCA9IG5ldyBQcm94eShkbC5wdXNoLCB7CiAgICAgICAgICAgICAgICBhcHBseTogZnVuY3Rpb24odGFyZ2V0LCB0aGlz
            QXJnLCBhcmdzKSB7CiAgICAgICAgICAgICAgICAgICAgZG9DYWxsYmFjayhhcmdzWzBdKTsKICAgICAgICAgICAgICAgICAg
            ICByZXR1cm4gUmVmbGVjdC5hcHBseSh0YXJnZXQsIHRoaXNBcmcsIGFyZ3MpOwogICAgICAgICAgICAgICAgfQogICAgICAg
            ICAgICB9KTsKICAgICAgICAgICAgaWYgKCBBcnJheS5pc0FycmF5KGRsKSApIHsKICAgICAgICAgICAgICAgIGNvbnN0IHEg
            PSBkbC5zbGljZSgpOwogICAgICAgICAgICAgICAgZm9yICggY29uc3QgaXRlbSBvZiBxICkgewogICAgICAgICAgICAgICAg
            ICAgIGRvQ2FsbGJhY2soaXRlbSk7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICB9CiAg
            ICAvLyBlbXB0eSBnYSBxdWV1ZQogICAgaWYgKCBnYVF1ZXVlIGluc3RhbmNlb2YgRnVuY3Rpb24gJiYgQXJyYXkuaXNBcnJh
            eShnYVF1ZXVlLnEpICkgewogICAgICAgIGNvbnN0IHEgPSBnYVF1ZXVlLnEuc2xpY2UoKTsKICAgICAgICBnYVF1ZXVlLnEu
            bGVuZ3RoID0gMDsKICAgICAgICBmb3IgKCBjb25zdCBlbnRyeSBvZiBxICkgewogICAgICAgICAgICBnYSguLi5lbnRyeSk7
            CiAgICAgICAgfQogICAgfQp9KSgpOwo=
            """
        ),
        RedirectResource(
            name: "google-analytics_cx_api.js",
            mimeType: "text/javascript",
            base64: """
            LyoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
            KioqKioqKioKCiAgICB1QmxvY2sgT3JpZ2luIC0gYSBicm93c2VyIGV4dGVuc2lvbiB0byBibG9jayByZXF1ZXN0cy4KICAg
            IENvcHlyaWdodCAoQykgMjAxOS1wcmVzZW50IFJheW1vbmQgSGlsbAoKICAgIFRoaXMgcHJvZ3JhbSBpcyBmcmVlIHNvZnR3
            YXJlOiB5b3UgY2FuIHJlZGlzdHJpYnV0ZSBpdCBhbmQvb3IgbW9kaWZ5CiAgICBpdCB1bmRlciB0aGUgdGVybXMgb2YgdGhl
            IEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGFzIHB1Ymxpc2hlZCBieQogICAgdGhlIEZyZWUgU29mdHdhcmUgRm91bmRh
            dGlvbiwgZWl0aGVyIHZlcnNpb24gMyBvZiB0aGUgTGljZW5zZSwgb3IKICAgIChhdCB5b3VyIG9wdGlvbikgYW55IGxhdGVy
            IHZlcnNpb24uCgogICAgVGhpcyBwcm9ncmFtIGlzIGRpc3RyaWJ1dGVkIGluIHRoZSBob3BlIHRoYXQgaXQgd2lsbCBiZSB1
            c2VmdWwsCiAgICBidXQgV0lUSE9VVCBBTlkgV0FSUkFOVFk7IHdpdGhvdXQgZXZlbiB0aGUgaW1wbGllZCB3YXJyYW50eSBv
            ZgogICAgTUVSQ0hBTlRBQklMSVRZIG9yIEZJVE5FU1MgRk9SIEEgUEFSVElDVUxBUiBQVVJQT1NFLiAgU2VlIHRoZQogICAg
            R05VIEdlbmVyYWwgUHVibGljIExpY2Vuc2UgZm9yIG1vcmUgZGV0YWlscy4KCiAgICBZb3Ugc2hvdWxkIGhhdmUgcmVjZWl2
            ZWQgYSBjb3B5IG9mIHRoZSBHTlUgR2VuZXJhbCBQdWJsaWMgTGljZW5zZQogICAgYWxvbmcgd2l0aCB0aGlzIHByb2dyYW0u
            ICBJZiBub3QsIHNlZSB7aHR0cDovL3d3dy5nbnUub3JnL2xpY2Vuc2VzL30uCgogICAgSG9tZTogaHR0cHM6Ly9naXRodWIu
            Y29tL2dvcmhpbGwvdUJsb2NrCiovCgooZnVuY3Rpb24oKSB7CiAgICAndXNlIHN0cmljdCc7CiAgICBjb25zdCBub29wZm4g
            PSBmdW5jdGlvbigpIHsKICAgIH07CiAgICB3aW5kb3cuY3hBcGkgPSB7CiAgICAgICAgY2hvb3NlVmFyaWF0aW9uOiBmdW5j
            dGlvbigpIHsKICAgICAgICAgICAgcmV0dXJuIDA7CiAgICAgICAgfSwKICAgICAgICBnZXRDaG9zZW5WYXJpYXRpb246IG5v
            b3BmbiwKICAgICAgICBzZXRBbGxvd0hhc2g6IG5vb3BmbiwKICAgICAgICBzZXRDaG9zZW5WYXJpYXRpb246IG5vb3BmbiwK
            ICAgICAgICBzZXRDb29raWVQYXRoOiBub29wZm4sCiAgICAgICAgc2V0RG9tYWluTmFtZTogbm9vcGZuCiAgICAgICAgfTsK
            fSkoKTsK
            """
        ),
        RedirectResource(
            name: "google-analytics_ga.js",
            mimeType: "text/javascript",
            base64: """
            LyoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
            KioqKioqKioKCiAgICB1QmxvY2sgT3JpZ2luIC0gYSBicm93c2VyIGV4dGVuc2lvbiB0byBibG9jayByZXF1ZXN0cy4KICAg
            IENvcHlyaWdodCAoQykgMjAxOS1wcmVzZW50IFJheW1vbmQgSGlsbAoKICAgIFRoaXMgcHJvZ3JhbSBpcyBmcmVlIHNvZnR3
            YXJlOiB5b3UgY2FuIHJlZGlzdHJpYnV0ZSBpdCBhbmQvb3IgbW9kaWZ5CiAgICBpdCB1bmRlciB0aGUgdGVybXMgb2YgdGhl
            IEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGFzIHB1Ymxpc2hlZCBieQogICAgdGhlIEZyZWUgU29mdHdhcmUgRm91bmRh
            dGlvbiwgZWl0aGVyIHZlcnNpb24gMyBvZiB0aGUgTGljZW5zZSwgb3IKICAgIChhdCB5b3VyIG9wdGlvbikgYW55IGxhdGVy
            IHZlcnNpb24uCgogICAgVGhpcyBwcm9ncmFtIGlzIGRpc3RyaWJ1dGVkIGluIHRoZSBob3BlIHRoYXQgaXQgd2lsbCBiZSB1
            c2VmdWwsCiAgICBidXQgV0lUSE9VVCBBTlkgV0FSUkFOVFk7IHdpdGhvdXQgZXZlbiB0aGUgaW1wbGllZCB3YXJyYW50eSBv
            ZgogICAgTUVSQ0hBTlRBQklMSVRZIG9yIEZJVE5FU1MgRk9SIEEgUEFSVElDVUxBUiBQVVJQT1NFLiAgU2VlIHRoZQogICAg
            R05VIEdlbmVyYWwgUHVibGljIExpY2Vuc2UgZm9yIG1vcmUgZGV0YWlscy4KCiAgICBZb3Ugc2hvdWxkIGhhdmUgcmVjZWl2
            ZWQgYSBjb3B5IG9mIHRoZSBHTlUgR2VuZXJhbCBQdWJsaWMgTGljZW5zZQogICAgYWxvbmcgd2l0aCB0aGlzIHByb2dyYW0u
            ICBJZiBub3QsIHNlZSB7aHR0cDovL3d3dy5nbnUub3JnL2xpY2Vuc2VzL30uCgogICAgSG9tZTogaHR0cHM6Ly9naXRodWIu
            Y29tL2dvcmhpbGwvdUJsb2NrCiovCgooZnVuY3Rpb24oKSB7CiAgICAndXNlIHN0cmljdCc7CiAgICBjb25zdCBub29wZm4g
            PSBmdW5jdGlvbigpIHsKICAgIH07CiAgICAvLwogICAgY29uc3QgR2FxID0gZnVuY3Rpb24oKSB7CiAgICB9OwogICAgR2Fx
            LnByb3RvdHlwZS5OYSA9IG5vb3BmbjsKICAgIEdhcS5wcm90b3R5cGUuTyA9IG5vb3BmbjsKICAgIEdhcS5wcm90b3R5cGUu
            U2EgPSBub29wZm47CiAgICBHYXEucHJvdG90eXBlLlRhID0gbm9vcGZuOwogICAgR2FxLnByb3RvdHlwZS5WYSA9IG5vb3Bm
            bjsKICAgIEdhcS5wcm90b3R5cGUuX2NyZWF0ZUFzeW5jVHJhY2tlciA9IG5vb3BmbjsKICAgIEdhcS5wcm90b3R5cGUuX2dl
            dEFzeW5jVHJhY2tlciA9IG5vb3BmbjsKICAgIEdhcS5wcm90b3R5cGUuX2dldFBsdWdpbiA9IG5vb3BmbjsKICAgIEdhcS5w
            cm90b3R5cGUucHVzaCA9IGZ1bmN0aW9uKGEpIHsKICAgICAgICBpZiAoIHR5cGVvZiBhID09PSAnZnVuY3Rpb24nICkgewog
            ICAgICAgICAgICBhKCk7IHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKCBBcnJheS5pc0FycmF5KGEpID09PSBmYWxz
            ZSApIHsgcmV0dXJuOyB9CiAgICAgICAgLy8gaHR0cHM6Ly9kZXZlbG9wZXJzLmdvb2dsZS5jb20vYW5hbHl0aWNzL2Rldmd1
            aWRlcy9jb2xsZWN0aW9uL2dhanMvbWV0aG9kcy9nYUpTQXBpRG9tYWluRGlyZWN0b3J5I19nYXQuR0FfVHJhY2tlcl8uX2xp
            bmsKICAgICAgICAvLyBodHRwczovL2dpdGh1Yi5jb20vdUJsb2NrT3JpZ2luL3VCbG9jay1pc3N1ZXMvaXNzdWVzLzE4MDcK
            ICAgICAgICBpZiAoCiAgICAgICAgICAgIHR5cGVvZiBhWzBdID09PSAnc3RyaW5nJyAmJgogICAgICAgICAgICAvKF58XC4p
            X2xpbmskLy50ZXN0KGFbMF0pICYmCiAgICAgICAgICAgIHR5cGVvZiBhWzFdID09PSAnc3RyaW5nJwogICAgICAgICkgewog
            ICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgd2luZG93LmxvY2F0aW9uLmFzc2lnbihhWzFdKTsKICAgICAgICAg
            ICAgfSBjYXRjaChleCkgewogICAgICAgICAgICB9CiAgICAgICAgfQogICAgICAgIC8vIGh0dHBzOi8vZ2l0aHViLmNvbS9n
            b3JoaWxsL3VCbG9jay9pc3N1ZXMvMjE2MgogICAgICAgIGlmICggYVswXSA9PT0gJ19zZXQnICYmIGFbMV0gPT09ICdoaXRD
            YWxsYmFjaycgJiYgdHlwZW9mIGFbMl0gPT09ICdmdW5jdGlvbicgKSB7CiAgICAgICAgICAgIGFbMl0oKTsKICAgICAgICB9
            CiAgICB9OwogICAgLy8KICAgIGNvbnN0IHRyYWNrZXIgPSAoZnVuY3Rpb24oKSB7CiAgICAgICAgY29uc3Qgb3V0ID0ge307
            CiAgICAgICAgY29uc3QgYXBpID0gWwogICAgICAgICAgICAnX2FkZElnbm9yZWRPcmdhbmljIF9hZGRJZ25vcmVkUmVmIF9h
            ZGRJdGVtIF9hZGRPcmdhbmljJywKICAgICAgICAgICAgJ19hZGRUcmFucyBfY2xlYXJJZ25vcmVkT3JnYW5pYyBfY2xlYXJJ
            Z25vcmVkUmVmIF9jbGVhck9yZ2FuaWMnLAogICAgICAgICAgICAnX2Nvb2tpZVBhdGhDb3B5IF9kZWxldGVDdXN0b21WYXIg
            X2dldE5hbWUgX3NldEFjY291bnQnLAogICAgICAgICAgICAnX2dldEFjY291bnQgX2dldENsaWVudEluZm8gX2dldERldGVj
            dEZsYXNoIF9nZXREZXRlY3RUaXRsZScsCiAgICAgICAgICAgICdfZ2V0TGlua2VyVXJsIF9nZXRMb2NhbEdpZlBhdGggX2dl
            dFNlcnZpY2VNb2RlIF9nZXRWZXJzaW9uJywKICAgICAgICAgICAgJ19nZXRWaXNpdG9yQ3VzdG9tVmFyIF9pbml0RGF0YSBf
            bGlua0J5UG9zdCcsCiAgICAgICAgICAgICdfc2V0QWxsb3dBbmNob3IgX3NldEFsbG93SGFzaCBfc2V0QWxsb3dMaW5rZXIg
            X3NldENhbXBDb250ZW50S2V5JywKICAgICAgICAgICAgJ19zZXRDYW1wTWVkaXVtS2V5IF9zZXRDYW1wTmFtZUtleSBfc2V0
            Q2FtcE5PS2V5IF9zZXRDYW1wU291cmNlS2V5JywKICAgICAgICAgICAgJ19zZXRDYW1wVGVybUtleSBfc2V0Q2FtcGFpZ25D
            b29raWVUaW1lb3V0IF9zZXRDYW1wYWlnblRyYWNrIF9zZXRDbGllbnRJbmZvJywKICAgICAgICAgICAgJ19zZXRDb29raWVQ
            YXRoIF9zZXRDb29raWVQZXJzaXN0ZW5jZSBfc2V0Q29va2llVGltZW91dCBfc2V0Q3VzdG9tVmFyJywKICAgICAgICAgICAg
            J19zZXREZXRlY3RGbGFzaCBfc2V0RGV0ZWN0VGl0bGUgX3NldERvbWFpbk5hbWUgX3NldExvY2FsR2lmUGF0aCcsCiAgICAg
            ICAgICAgICdfc2V0TG9jYWxSZW1vdGVTZXJ2ZXJNb2RlIF9zZXRMb2NhbFNlcnZlck1vZGUgX3NldFJlZmVycmVyT3ZlcnJp
            ZGUgX3NldFJlbW90ZVNlcnZlck1vZGUnLAogICAgICAgICAgICAnX3NldFNhbXBsZVJhdGUgX3NldFNlc3Npb25UaW1lb3V0
            IF9zZXRTaXRlU3BlZWRTYW1wbGVSYXRlIF9zZXRTZXNzaW9uQ29va2llVGltZW91dCcsCiAgICAgICAgICAgICdfc2V0VmFy
            IF9zZXRWaXNpdG9yQ29va2llVGltZW91dCBfdHJhY2tFdmVudCBfdHJhY2tQYWdlTG9hZFRpbWUnLAogICAgICAgICAgICAn
            X3RyYWNrUGFnZXZpZXcgX3RyYWNrU29jaWFsIF90cmFja1RpbWluZyBfdHJhY2tUcmFucycsCiAgICAgICAgICAgICdfdmlz
            aXRDb2RlJwogICAgICAgIF0uam9pbignICcpLnNwbGl0KC9ccysvKTsKICAgICAgICBmb3IgKCBjb25zdCBtZXRob2Qgb2Yg
            YXBpICkgewogICAgICAgICAgICBvdXRbbWV0aG9kXSA9IG5vb3BmbjsKICAgICAgICB9CiAgICAgICAgb3V0Ll9nZXRMaW5r
            ZXJVcmwgPSBmdW5jdGlvbihhKSB7CiAgICAgICAgICAgIHJldHVybiBhOwogICAgICAgIH07CiAgICAgICAgLy8gaHR0cHM6
            Ly9naXRodWIuY29tL0FkZ3VhcmRUZWFtL1NjcmlwdGxldHMvaXNzdWVzLzE1NAogICAgICAgIG91dC5fbGluayA9IGZ1bmN0
            aW9uKGEpIHsKICAgICAgICAgICAgaWYgKCB0eXBlb2YgYSAhPT0gJ3N0cmluZycgKSB7IHJldHVybjsgfQogICAgICAgICAg
            ICB0cnkgewogICAgICAgICAgICAgICAgd2luZG93LmxvY2F0aW9uLmFzc2lnbihhKTsKICAgICAgICAgICAgfSBjYXRjaChl
            eCkgewogICAgICAgICAgICB9CiAgICAgICAgfTsKICAgICAgICByZXR1cm4gb3V0OwogICAgfSkoKTsKICAgIC8vCiAgICBj
            b25zdCBHYXQgPSBmdW5jdGlvbigpIHsKICAgIH07CiAgICBHYXQucHJvdG90eXBlLl9hbm9ueW1pemVJUCA9IG5vb3BmbjsK
            ICAgIEdhdC5wcm90b3R5cGUuX2NyZWF0ZVRyYWNrZXIgPSBub29wZm47CiAgICBHYXQucHJvdG90eXBlLl9mb3JjZVNTTCA9
            IG5vb3BmbjsKICAgIEdhdC5wcm90b3R5cGUuX2dldFBsdWdpbiA9IG5vb3BmbjsKICAgIEdhdC5wcm90b3R5cGUuX2dldFRy
            YWNrZXIgPSBmdW5jdGlvbigpIHsKICAgICAgICByZXR1cm4gdHJhY2tlcjsKICAgIH07CiAgICBHYXQucHJvdG90eXBlLl9n
            ZXRUcmFja2VyQnlOYW1lID0gZnVuY3Rpb24oKSB7CiAgICAgICAgcmV0dXJuIHRyYWNrZXI7CiAgICB9OwogICAgR2F0LnBy
            b3RvdHlwZS5fZ2V0VHJhY2tlcnMgPSBub29wZm47CiAgICBHYXQucHJvdG90eXBlLmFhID0gbm9vcGZuOwogICAgR2F0LnBy
            b3RvdHlwZS5hYiA9IG5vb3BmbjsKICAgIEdhdC5wcm90b3R5cGUuaGIgPSBub29wZm47CiAgICBHYXQucHJvdG90eXBlLmxh
            ID0gbm9vcGZuOwogICAgR2F0LnByb3RvdHlwZS5vYSA9IG5vb3BmbjsKICAgIEdhdC5wcm90b3R5cGUucGEgPSBub29wZm47
            CiAgICBHYXQucHJvdG90eXBlLnUgPSBub29wZm47CiAgICBjb25zdCBnYXQgPSBuZXcgR2F0KCk7CiAgICB3aW5kb3cuX2dh
            dCA9IGdhdDsKICAgIC8vCiAgICBjb25zdCBnYXEgPSBuZXcgR2FxKCk7CiAgICAoZnVuY3Rpb24oKSB7CiAgICAgICAgY29u
            c3QgYWEgPSB3aW5kb3cuX2dhcSB8fCBbXTsKICAgICAgICBpZiAoIEFycmF5LmlzQXJyYXkoYWEpICkgewogICAgICAgICAg
            ICB3aGlsZSAoIGFhWzBdICkgewogICAgICAgICAgICAgICAgZ2FxLnB1c2goYWEuc2hpZnQoKSk7CiAgICAgICAgICAgIH0K
            ICAgICAgICB9CiAgICB9KSgpOwogICAgd2luZG93Ll9nYXEgPSBnYXEucWYgPSBnYXE7Cn0pKCk7Cg==
            """
        ),
        RedirectResource(
            name: "google-analytics_inpage_linkid.js",
            mimeType: "text/javascript",
            base64: """
            LyoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
            KioqKioqKioKCiAgICB1QmxvY2sgT3JpZ2luIC0gYSBicm93c2VyIGV4dGVuc2lvbiB0byBibG9jayByZXF1ZXN0cy4KICAg
            IENvcHlyaWdodCAoQykgMjAxOS1wcmVzZW50IFJheW1vbmQgSGlsbAoKICAgIFRoaXMgcHJvZ3JhbSBpcyBmcmVlIHNvZnR3
            YXJlOiB5b3UgY2FuIHJlZGlzdHJpYnV0ZSBpdCBhbmQvb3IgbW9kaWZ5CiAgICBpdCB1bmRlciB0aGUgdGVybXMgb2YgdGhl
            IEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGFzIHB1Ymxpc2hlZCBieQogICAgdGhlIEZyZWUgU29mdHdhcmUgRm91bmRh
            dGlvbiwgZWl0aGVyIHZlcnNpb24gMyBvZiB0aGUgTGljZW5zZSwgb3IKICAgIChhdCB5b3VyIG9wdGlvbikgYW55IGxhdGVy
            IHZlcnNpb24uCgogICAgVGhpcyBwcm9ncmFtIGlzIGRpc3RyaWJ1dGVkIGluIHRoZSBob3BlIHRoYXQgaXQgd2lsbCBiZSB1
            c2VmdWwsCiAgICBidXQgV0lUSE9VVCBBTlkgV0FSUkFOVFk7IHdpdGhvdXQgZXZlbiB0aGUgaW1wbGllZCB3YXJyYW50eSBv
            ZgogICAgTUVSQ0hBTlRBQklMSVRZIG9yIEZJVE5FU1MgRk9SIEEgUEFSVElDVUxBUiBQVVJQT1NFLiAgU2VlIHRoZQogICAg
            R05VIEdlbmVyYWwgUHVibGljIExpY2Vuc2UgZm9yIG1vcmUgZGV0YWlscy4KCiAgICBZb3Ugc2hvdWxkIGhhdmUgcmVjZWl2
            ZWQgYSBjb3B5IG9mIHRoZSBHTlUgR2VuZXJhbCBQdWJsaWMgTGljZW5zZQogICAgYWxvbmcgd2l0aCB0aGlzIHByb2dyYW0u
            ICBJZiBub3QsIHNlZSB7aHR0cDovL3d3dy5nbnUub3JnL2xpY2Vuc2VzL30uCgogICAgSG9tZTogaHR0cHM6Ly9naXRodWIu
            Y29tL2dvcmhpbGwvdUJsb2NrCiovCgooZnVuY3Rpb24oKSB7CiAgICAndXNlIHN0cmljdCc7CiAgICB3aW5kb3cuX2dhcSA9
            IHdpbmRvdy5fZ2FxIHx8IHsKICAgICAgICBwdXNoOiBmdW5jdGlvbigpIHsKICAgICAgICB9CiAgICB9Owp9KSgpOwo=
            """
        ),
        RedirectResource(
            name: "google-ima.js",
            mimeType: "text/javascript",
            base64: """
            LyoqCiAqIAogKiBTb3VyY2UgYmVsb3cgaXMgYmFzZWQgb24gTW96aWxsYSBzb3VyY2UgY29kZToKICogaHR0cHM6Ly9zZWFy
            Y2hmb3gub3JnL21vemlsbGEtY2VudHJhbC9yZXYvZDMxN2U5M2Q5YTU5YzllNGMwNmFkYTg1ZmJmZjlmNmExY2VhYWFkMS9i
            cm93c2VyL2V4dGVuc2lvbnMvd2ViY29tcGF0L3NoaW1zL2dvb2dsZS1pbWEuanMKICogCiAqIE1vZGlmaWNhdGlvbnMgdG8g
            dGhlIG9yaWdpbmFsIGNvZGUgYmVsb3cgdGhpcyBjb21tZW50OgogKiAtIEF2b2lkIEpTIHN5bnRheCBub3Qgc3VwcG9ydGVk
            IGJ5IG9sZGVyIGJyb3dzZXIgdmVyc2lvbnMKICogLSBBZGQgbWlzc2luZyBzaGltIGV2ZW50CiAqIC0gTW9kaWZpZWQgdG8g
            YXZvaWQganNoaW50IHdhcm5pbmdzIGFzIHBlciB1Qk8ncyBjb25maWcKICogLSBBZGRlZCBgT21pZFZlcmlmaWNhdGlvblZl
            bmRvcmAgdG8gYGltYWAKICogLSBIYXZlIGBBZEVycm9yLmdldElubmVyRXJyb3IoKWAgcmV0dXJuIGBudWxsYAogKiAtIEhh
            dmUgYEFkRGlzcGxheUNvbnRhaW5lcmAgY29uc3RydWN0b3IgYWRkIERJViBlbGVtZW50IHRvIGNvbnRhaW5lcgogKiAtIEFk
            ZGVkIG1pc3NpbmcgZXZlbnQgZGlzcGF0Y2hlciBmdW5jdGlvbmFsaXR5CiAqIC0gQ29ycmVjdGVkIHJldHVybiB0eXBlIG9m
            IGBBZC5nZXRVbml2ZXJzYWxBZElkcygpYAogKiAtIENvcnJlY3RlZCB0eXBvIGluIGBVbml2ZXJzYWxBZElkSW5mby5nZXRB
            ZElkVmFsdWUoKWAgbWV0aG9kIG5hbWUKICogLSBDb3JyZWN0ZWQgZGlzcGF0Y2ggb2YgTE9BRCBldmVudCB3aGVuIHByZWxv
            YWRpbmcgaXMgZW5hYmxlZAogKiAtIENvcnJlY3RlZCBkaXNwYXRjaCBvZiBDT05URU5UX1BBVVNFL1JFU1VNRV9SRVFVRVNU
            RUQgZXZlbnRzCiAqIC0gUmVtb3ZlIHRlc3QgZm9yIGF1dG8tcGxheSBpbiByZXF1ZXN0QWRzKCk6IGFsd2F5cyBiZWhhdmUg
            YXMgaWYgYXV0by1wbGF5CiAqICAgaXMgZGlzYWJsZWQKICogCiAqIFJlbGF0ZWQgaXNzdWU6CiAqIC0gaHR0cHM6Ly9naXRo
            dWIuY29tL3VCbG9ja09yaWdpbi91QmxvY2staXNzdWVzL2lzc3Vlcy8yMTU4CiAqIC0gaHR0cHM6Ly9naXRodWIuY29tL3VC
            bG9ja09yaWdpbi91QXNzZXRzL2lzc3Vlcy8zMDEzNAogKiAtIGh0dHBzOi8vZ2l0aHViLmNvbS91QmxvY2tPcmlnaW4vdUFz
            c2V0cy9pc3N1ZXMvMzEwMTgKICogCioqLwoKLyogZXNsaW50LWRpc2FibGUgaW5kZW50ICovCgondXNlIHN0cmljdCc7Cgov
            KiBUaGlzIFNvdXJjZSBDb2RlIEZvcm0gaXMgc3ViamVjdCB0byB0aGUgdGVybXMgb2YgdGhlIE1vemlsbGEgUHVibGljCiAq
            IExpY2Vuc2UsIHYuIDIuMC4gSWYgYSBjb3B5IG9mIHRoZSBNUEwgd2FzIG5vdCBkaXN0cmlidXRlZCB3aXRoIHRoaXMKICog
            ZmlsZSwgWW91IGNhbiBvYnRhaW4gb25lIGF0IGh0dHA6Ly9tb3ppbGxhLm9yZy9NUEwvMi4wLy4gKi8KCi8qKgogKiBCdWcg
            MTcxMzY5MCAtIFNoaW0gR29vZ2xlIEludGVyYWN0aXZlIE1lZGlhIEFkcyBpbWEzLmpzCiAqCiAqIE1hbnkgc2l0ZXMgdXNl
            IGltYTMuanMgZm9yIGFkIGJpZGRpbmcgYW5kIHBsYWNlbWVudCwgb2Z0ZW4gaW4gY29uanVuY3Rpb24KICogd2l0aCBHb29n
            bGUgUHVibGlzaGVyIFRhZ3MsIFByZWJpZC5qcyBhbmQvb3Igb3RoZXIgc2NyaXB0cy4gVGhpcyBzaGltCiAqIHByb3ZpZGVz
            IGEgc3R1YmJlZC1vdXQgdmVyc2lvbiBvZiB0aGUgQVBJIHdoaWNoIGhlbHBzIHdvcmsgYXJvdW5kIHJlbGF0ZWQKICogc2l0
            ZSBicmVha2FnZSwgc3VjaCBhcyBibGFjayBieG9lcyB3aGVyZSB2aWRlb3Mgb3VnaHQgdG8gYmUgcGxhY2VkLgogKi8KCmlm
            ICghd2luZG93Lmdvb2dsZSB8fCAhd2luZG93Lmdvb2dsZS5pbWEgfHwgIXdpbmRvdy5nb29nbGUuaW1hLlZFUlNJT04pIHsK
            ICBjb25zdCBWRVJTSU9OID0gIjMuNzY0LjAiOwogIGNvbnN0IGltYSA9IHt9OwoKICBjbGFzcyBBZERpc3BsYXlDb250YWlu
            ZXIgewogICAgY29uc3RydWN0b3IoY29udGFpbmVyRWxlbWVudCkgewogICAgICBjb25zdCBkaXZFbGVtZW50ID0gZG9jdW1l
            bnQuY3JlYXRlRWxlbWVudCgiZGl2Iik7CiAgICAgIGRpdkVsZW1lbnQuc3R5bGUuc2V0UHJvcGVydHkoImRpc3BsYXkiLCAi
            bm9uZSIsICJpbXBvcnRhbnQiKTsKICAgICAgZGl2RWxlbWVudC5zdHlsZS5zZXRQcm9wZXJ0eSgidmlzaWJpbGl0eSIsICJj
            b2xsYXBzZSIsICJpbXBvcnRhbnQiKTsKICAgICAgY29udGFpbmVyRWxlbWVudC5hcHBlbmRDaGlsZChkaXZFbGVtZW50KTsK
            ICAgIH0KICAgIGRlc3Ryb3koKSB7fQogICAgaW5pdGlhbGl6ZSgpIHt9CiAgfQoKICBjbGFzcyBJbWFTZGtTZXR0aW5ncyB7
            CiAgICBjb25zdHJ1Y3RvcigpIHsKICAgICAgdGhpcy5jID0gdHJ1ZTsKICAgICAgdGhpcy5mID0ge307CiAgICAgIHRoaXMu
            aSA9IGZhbHNlOwogICAgICB0aGlzLmwgPSAiIjsKICAgICAgdGhpcy5wID0gIiI7CiAgICAgIHRoaXMuciA9IDA7CiAgICAg
            IHRoaXMudCA9ICIiOwogICAgICB0aGlzLnYgPSAiIjsKICAgIH0KICAgIGdldENvbXBhbmlvbkJhY2tmaWxsKCkge30KICAg
            IGdldERpc2FibGVDdXN0b21QbGF5YmFja0ZvcklPUzEwUGx1cygpIHsKICAgICAgcmV0dXJuIHRoaXMuaTsKICAgIH0KICAg
            IGdldEZlYXR1cmVGbGFncygpIHsKICAgICAgcmV0dXJuIHRoaXMuZjsKICAgIH0KICAgIGdldExvY2FsZSgpIHsKICAgICAg
            cmV0dXJuIHRoaXMubDsKICAgIH0KICAgIGdldE51bVJlZGlyZWN0cygpIHsKICAgICAgcmV0dXJuIHRoaXMucjsKICAgIH0K
            ICAgIGdldFBsYXllclR5cGUoKSB7CiAgICAgIHJldHVybiB0aGlzLnQ7CiAgICB9CiAgICBnZXRQbGF5ZXJWZXJzaW9uKCkg
            ewogICAgICByZXR1cm4gdGhpcy52OwogICAgfQogICAgZ2V0UHBpZCgpIHsKICAgICAgcmV0dXJuIHRoaXMucDsKICAgIH0K
            ICAgIGlzQ29va2llc0VuYWJsZWQoKSB7CiAgICAgIHJldHVybiB0aGlzLmM7CiAgICB9CiAgICBzZXRBdXRvUGxheUFkQnJl
            YWtzKCkge30KICAgIHNldENvbXBhbmlvbkJhY2tmaWxsKCkge30KICAgIHNldENvb2tpZXNFbmFibGVkKGMpIHsKICAgICAg
            dGhpcy5jID0gISFjOwogICAgfQogICAgc2V0RGlzYWJsZUN1c3RvbVBsYXliYWNrRm9ySU9TMTBQbHVzKGkpIHsKICAgICAg
            dGhpcy5pID0gISFpOwogICAgfQogICAgc2V0RmVhdHVyZUZsYWdzKGYpIHsKICAgICAgdGhpcy5mID0gZjsKICAgIH0KICAg
            IHNldExvY2FsZShsKSB7CiAgICAgIHRoaXMubCA9IGw7CiAgICB9CiAgICBzZXROdW1SZWRpcmVjdHMocikgewogICAgICB0
            aGlzLnIgPSByOwogICAgfQogICAgc2V0UGxheWVyVHlwZSh0KSB7CiAgICAgIHRoaXMudCA9IHQ7CiAgICB9CiAgICBzZXRQ
            bGF5ZXJWZXJzaW9uKHYpIHsKICAgICAgdGhpcy52ID0gdjsKICAgIH0KICAgIHNldFBwaWQocCkgewogICAgICB0aGlzLnAg
            PSBwOwogICAgfQogICAgc2V0U2Vzc2lvbklkKC8qcyovKSB7fQogICAgc2V0VnBhaWRBbGxvd2VkKC8qYSovKSB7fQogICAg
            c2V0VnBhaWRNb2RlKC8qbSovKSB7fQoKICAgIC8vIGh0dHBzOi8vZ2l0aHViLmNvbS91QmxvY2tPcmlnaW4vdUJsb2NrLWlz
            c3Vlcy9pc3N1ZXMvMjI2NSNpc3N1ZWNvbW1lbnQtMTYzNzA5NDE0OQogICAgZ2V0RGlzYWJsZUZsYXNoQWRzKCkgewogICAg
            fQogICAgc2V0RGlzYWJsZUZsYXNoQWRzKCkgewogICAgfQogIH0KICBJbWFTZGtTZXR0aW5ncy5Db21wYW5pb25CYWNrZmls
            bE1vZGUgPSB7CiAgICBBTFdBWVM6ICJhbHdheXMiLAogICAgT05fTUFTVEVSX0FEOiAib25fbWFzdGVyX2FkIiwKICB9Owog
            IEltYVNka1NldHRpbmdzLlZwYWlkTW9kZSA9IHsKICAgIERJU0FCTEVEOiAwLAogICAgRU5BQkxFRDogMSwKICAgIElOU0VD
            VVJFOiAyLAogIH07CgogIGNsYXNzIEV2ZW50SGFuZGxlciB7CiAgICBjb25zdHJ1Y3RvcigpIHsKICAgICAgdGhpcy5saXN0
            ZW5lcnMgPSBuZXcgTWFwKCk7CiAgICB9CgogICAgX2Rpc3BhdGNoKGUpIHsKICAgICAgbGV0IGxpc3RlbmVycyA9IHRoaXMu
            bGlzdGVuZXJzLmdldChlLnR5cGUpOwogICAgICBsaXN0ZW5lcnMgPSBsaXN0ZW5lcnMgPyBBcnJheS5mcm9tKGxpc3RlbmVy
            cy52YWx1ZXMoKSkgOiBbXTsKICAgICAgZm9yIChjb25zdCBsaXN0ZW5lciBvZiBsaXN0ZW5lcnMpIHsKICAgICAgICB0cnkg
            ewogICAgICAgICAgbGlzdGVuZXIoZSk7CiAgICAgICAgfSBjYXRjaCAocikgewogICAgICAgICAgY29uc29sZS5lcnJvcihy
            KTsKICAgICAgICB9CiAgICAgIH0KICAgIH0KCiAgICBhZGRFdmVudExpc3RlbmVyKHR5cGVzLCBjLCBvcHRpb25zLCBjb250
            ZXh0KSB7CiAgICAgIGlmICghQXJyYXkuaXNBcnJheSh0eXBlcykpIHsKICAgICAgICB0eXBlcyA9IFt0eXBlc107CiAgICAg
            IH0KCiAgICAgIGZvciAoY29uc3QgdCBvZiB0eXBlcykgewogICAgICAgIGlmICghdGhpcy5saXN0ZW5lcnMuaGFzKHQpKSB7
            CiAgICAgICAgICB0aGlzLmxpc3RlbmVycy5zZXQodCwgbmV3IE1hcCgpKTsKICAgICAgICB9CiAgICAgICAgdGhpcy5saXN0
            ZW5lcnMuZ2V0KHQpLnNldChjLCBjLmJpbmQoY29udGV4dCB8fCB0aGlzKSk7CiAgICAgIH0KICAgIH0KCiAgICByZW1vdmVF
            dmVudExpc3RlbmVyKHR5cGVzLCBjKSB7CiAgICAgIGlmICghQXJyYXkuaXNBcnJheSh0eXBlcykpIHsKICAgICAgICB0eXBl
            cyA9IFt0eXBlc107CiAgICAgIH0KCiAgICAgIGZvciAoY29uc3QgdCBvZiB0eXBlcykgewogICAgICAgIGNvbnN0IHR5cGVT
            ZXQgPSB0aGlzLmxpc3RlbmVycy5nZXQodCk7CiAgICAgICAgaWYgKHR5cGVTZXQpIHsKICAgICAgICAgIHR5cGVTZXQuZGVs
            ZXRlKGMpOwogICAgICAgIH0KICAgICAgfQogICAgfQogIH0KCiAgY2xhc3MgQWRzTG9hZGVyIGV4dGVuZHMgRXZlbnRIYW5k
            bGVyIHsKICAgIGNvbnN0cnVjdG9yKCkgewogICAgICBzdXBlcigpOwogICAgICB0aGlzLnNldHRpbmdzID0gbmV3IEltYVNk
            a1NldHRpbmdzKCk7CiAgICB9CiAgICBjb250ZW50Q29tcGxldGUoKSB7fQogICAgZGVzdHJveSgpIHt9CiAgICBnZXRTZXR0
            aW5ncygpIHsKICAgICAgcmV0dXJuIHRoaXMuc2V0dGluZ3M7CiAgICB9CiAgICBnZXRWZXJzaW9uKCkgewogICAgICByZXR1
            cm4gVkVSU0lPTjsKICAgIH0KICAgIHJlcXVlc3RBZHMoX3IsIF9jKSB7CiAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZSgo
            KSA9PiB7CiAgICAgICAgY29uc3QgeyBBRFNfTUFOQUdFUl9MT0FERUQgfSA9IEFkc01hbmFnZXJMb2FkZWRFdmVudC5UeXBl
            OwogICAgICAgIGNvbnN0IGV2ZW50ID0gbmV3IGltYS5BZHNNYW5hZ2VyTG9hZGVkRXZlbnQoQURTX01BTkFHRVJfTE9BREVE
            LCBfciwgX2MpOwogICAgICAgIHRoaXMuX2Rpc3BhdGNoKGV2ZW50KTsKICAgICAgfSk7CiAgICAgIGNvbnN0IGVycm9yID0g
            bmV3IGltYS5BZEVycm9yKAogICAgICAgICJhZFBsYXlFcnJvciIsCiAgICAgICAgMTIwNSwgMTIwNSwKICAgICAgICAiVGhl
            IGJyb3dzZXIgcHJldmVudGVkIHBsYXliYWNrIGluaXRpYXRlZCB3aXRob3V0IHVzZXIgaW50ZXJhY3Rpb24uIiwKICAgICAg
            ICBfciwgX2MKICAgICAgKTsKICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCAoKSA9PiB7CiAgICAgICAgdGhpcy5fZGlz
            cGF0Y2gobmV3IGltYS5BZEVycm9yRXZlbnQoZXJyb3IpKTsKICAgICAgfSk7CiAgICB9CiAgfQoKICBjbGFzcyBBZHNNYW5h
            Z2VyIGV4dGVuZHMgRXZlbnRIYW5kbGVyIHsKICAgIGNvbnN0cnVjdG9yKCkgewogICAgICBzdXBlcigpOwogICAgICB0aGlz
            LnZvbHVtZSA9IDE7CiAgICAgIHRoaXMuX2VuYWJsZVByZWxvYWRpbmcgPSBmYWxzZTsKICAgIH0KICAgIGNvbGxhcHNlKCkg
            e30KICAgIGNvbmZpZ3VyZUFkc01hbmFnZXIoKSB7fQogICAgZGVzdHJveSgpIHt9CiAgICBkaXNjYXJkQWRCcmVhaygpIHt9
            CiAgICBleHBhbmQoKSB7fQogICAgZm9jdXMoKSB7fQogICAgZ2V0QWRTa2lwcGFibGVTdGF0ZSgpIHsKICAgICAgcmV0dXJu
            IGZhbHNlOwogICAgfQogICAgZ2V0Q3VlUG9pbnRzKCkgewogICAgICByZXR1cm4gWzBdOwogICAgfQogICAgZ2V0Q3VycmVu
            dEFkKCkgewogICAgICByZXR1cm4gY3VycmVudEFkOwogICAgfQogICAgZ2V0Q3VycmVudEFkQ3VlUG9pbnRzKCkgewogICAg
            ICByZXR1cm4gW107CiAgICB9CiAgICBnZXRSZW1haW5pbmdUaW1lKCkgewogICAgICByZXR1cm4gMDsKICAgIH0KICAgIGdl
            dFZvbHVtZSgpIHsKICAgICAgcmV0dXJuIHRoaXMudm9sdW1lOwogICAgfQogICAgaW5pdCgvKncsIGgsIG0sIGUqLykgewog
            ICAgICBpZiAodGhpcy5fZW5hYmxlUHJlbG9hZGluZykgewogICAgICAgIHRoaXMuX2Rpc3BhdGNoKG5ldyBpbWEuQWRFdmVu
            dChBZEV2ZW50LlR5cGUuTE9BREVEKSk7CiAgICAgIH0KICAgIH0KICAgIGlzQ3VzdG9tQ2xpY2tUcmFja2luZ1VzZWQoKSB7
            CiAgICAgIHJldHVybiBmYWxzZTsKICAgIH0KICAgIGlzQ3VzdG9tUGxheWJhY2tVc2VkKCkgewogICAgICByZXR1cm4gZmFs
            c2U7CiAgICB9CiAgICBwYXVzZSgpIHt9CiAgICByZXF1ZXN0TmV4dEFkQnJlYWsoKSB7fQogICAgcmVzaXplKC8qdywgaCwg
            bSovKSB7fQogICAgcmVzdW1lKCkge30KICAgIHNldFZvbHVtZSh2KSB7CiAgICAgIHRoaXMudm9sdW1lID0gdjsKICAgIH0K
            ICAgIHNraXAoKSB7fQogICAgc3RhcnQoKSB7CiAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7CiAgICAgICAg
            Zm9yIChjb25zdCB0eXBlIG9mIFsKICAgICAgICAgIEFkRXZlbnQuVHlwZS5MT0FERUQsCiAgICAgICAgICBBZEV2ZW50LlR5
            cGUuU1RBUlRFRCwKICAgICAgICAgIEFkRXZlbnQuVHlwZS5DT05URU5UX1BBVVNFX1JFUVVFU1RFRCwKICAgICAgICAgIEFk
            RXZlbnQuVHlwZS5BRF9CVUZGRVJJTkcsCiAgICAgICAgICBBZEV2ZW50LlR5cGUuRklSU1RfUVVBUlRJTEUsCiAgICAgICAg
            ICBBZEV2ZW50LlR5cGUuTUlEUE9JTlQsCiAgICAgICAgICBBZEV2ZW50LlR5cGUuVEhJUkRfUVVBUlRJTEUsCiAgICAgICAg
            ICBBZEV2ZW50LlR5cGUuQ09NUExFVEUsCiAgICAgICAgICBBZEV2ZW50LlR5cGUuQUxMX0FEU19DT01QTEVURUQsCiAgICAg
            ICAgICBBZEV2ZW50LlR5cGUuQ09OVEVOVF9SRVNVTUVfUkVRVUVTVEVELAogICAgICAgIF0pIHsKICAgICAgICAgIHRyeSB7
            CiAgICAgICAgICAgIHRoaXMuX2Rpc3BhdGNoKG5ldyBpbWEuQWRFdmVudCh0eXBlKSk7CiAgICAgICAgICB9IGNhdGNoIChl
            KSB7CiAgICAgICAgICAgIGNvbnNvbGUuZXJyb3IoZSk7CiAgICAgICAgICB9CiAgICAgICAgfQogICAgICB9KTsKICAgIH0K
            ICAgIHN0b3AoKSB7fQogICAgdXBkYXRlQWRzUmVuZGVyaW5nU2V0dGluZ3MoLypzKi8pIHt9CiAgfQoKICBjbGFzcyBBZHNS
            ZW5kZXJpbmdTZXR0aW5ncyB7fQoKICBjbGFzcyBBZHNSZXF1ZXN0IHsKICAgIHNldEFkV2lsbEF1dG9QbGF5KCkge30KICAg
            IHNldEFkV2lsbFBsYXlNdXRlZCgpIHt9CiAgICBzZXRDb250aW51b3VzUGxheWJhY2soKSB7fQogIH0KCiAgY2xhc3MgQWRQ
            b2RJbmZvIHsKICAgIGdldEFkUG9zaXRpb24oKSB7CiAgICAgIHJldHVybiAxOwogICAgfQogICAgZ2V0SXNCdW1wZXIoKSB7
            CiAgICAgIHJldHVybiBmYWxzZTsKICAgIH0KICAgIGdldE1heER1cmF0aW9uKCkgewogICAgICByZXR1cm4gLTE7CiAgICB9
            CiAgICBnZXRQb2RJbmRleCgpIHsKICAgICAgcmV0dXJuIDE7CiAgICB9CiAgICBnZXRUaW1lT2Zmc2V0KCkgewogICAgICBy
            ZXR1cm4gMDsKICAgIH0KICAgIGdldFRvdGFsQWRzKCkgewogICAgICByZXR1cm4gMTsKICAgIH0KICB9CgogIGNsYXNzIEFk
            IHsKICAgIGNvbnN0cnVjdG9yKCkgewogICAgICB0aGlzLl9waSA9IG5ldyBBZFBvZEluZm8oKTsKICAgIH0KICAgIGdldEFk
            SWQoKSB7CiAgICAgIHJldHVybiAiIjsKICAgIH0KICAgIGdldEFkUG9kSW5mbygpIHsKICAgICAgcmV0dXJuIHRoaXMuX3Bp
            OwogICAgfQogICAgZ2V0QWRTeXN0ZW0oKSB7CiAgICAgIHJldHVybiAiIjsKICAgIH0KICAgIGdldEFkdmVydGlzZXJOYW1l
            KCkgewogICAgICByZXR1cm4gIiI7CiAgICB9CiAgICBnZXRBcGlGcmFtZXdvcmsoKSB7CiAgICAgIHJldHVybiBudWxsOwog
            ICAgfQogICAgZ2V0Q29tcGFuaW9uQWRzKCkgewogICAgICByZXR1cm4gW107CiAgICB9CiAgICBnZXRDb250ZW50VHlwZSgp
            IHsKICAgICAgcmV0dXJuICIiOwogICAgfQogICAgZ2V0Q3JlYXRpdmVBZElkKCkgewogICAgICByZXR1cm4gIiI7CiAgICB9
            CiAgICBnZXRDcmVhdGl2ZUlkKCkgewogICAgICByZXR1cm4gIiI7CiAgICB9CiAgICBnZXREZWFsSWQoKSB7CiAgICAgIHJl
            dHVybiAiIjsKICAgIH0KICAgIGdldERlc2NyaXB0aW9uKCkgewogICAgICByZXR1cm4gIiI7CiAgICB9CiAgICBnZXREdXJh
            dGlvbigpIHsKICAgICAgcmV0dXJuIDguNTsKICAgIH0KICAgIGdldEhlaWdodCgpIHsKICAgICAgcmV0dXJuIDA7CiAgICB9
            CiAgICBnZXRNZWRpYVVybCgpIHsKICAgICAgcmV0dXJuIG51bGw7CiAgICB9CiAgICBnZXRNaW5TdWdnZXN0ZWREdXJhdGlv
            bigpIHsKICAgICAgcmV0dXJuIC0yOwogICAgfQogICAgZ2V0U2tpcFRpbWVPZmZzZXQoKSB7CiAgICAgIHJldHVybiAtMTsK
            ICAgIH0KICAgIGdldFN1cnZleVVybCgpIHsKICAgICAgcmV0dXJuIG51bGw7CiAgICB9CiAgICBnZXRUaXRsZSgpIHsKICAg
            ICAgcmV0dXJuICIiOwogICAgfQogICAgZ2V0VHJhZmZpY2tpbmdQYXJhbWV0ZXJzKCkgewogICAgICByZXR1cm4ge307CiAg
            ICB9CiAgICBnZXRUcmFmZmlja2luZ1BhcmFtZXRlcnNTdHJpbmcoKSB7CiAgICAgIHJldHVybiAiIjsKICAgIH0KICAgIGdl
            dFVpRWxlbWVudHMoKSB7CiAgICAgIHJldHVybiBbIiJdOwogICAgfQogICAgZ2V0VW5pdmVyc2FsQWRJZFJlZ2lzdHJ5KCkg
            ewogICAgICByZXR1cm4gInVua25vd24iOwogICAgfQogICAgZ2V0VW5pdmVyc2FsQWRJZHMoKSB7CiAgICAgIHJldHVybiBb
            bmV3IFVuaXZlcnNhbEFkSWRJbmZvKCldOwogICAgfQogICAgZ2V0VW5pdmVyc2FsQWRJZFZhbHVlKCkgewogICAgICByZXR1
            cm4gInVua25vd24iOwogICAgfQogICAgZ2V0VmFzdE1lZGlhQml0cmF0ZSgpIHsKICAgICAgcmV0dXJuIDA7CiAgICB9CiAg
            ICBnZXRWYXN0TWVkaWFIZWlnaHQoKSB7CiAgICAgIHJldHVybiAwOwogICAgfQogICAgZ2V0VmFzdE1lZGlhV2lkdGgoKSB7
            CiAgICAgIHJldHVybiAwOwogICAgfQogICAgZ2V0V2lkdGgoKSB7CiAgICAgIHJldHVybiAwOwogICAgfQogICAgZ2V0V3Jh
            cHBlckFkSWRzKCkgewogICAgICByZXR1cm4gWyIiXTsKICAgIH0KICAgIGdldFdyYXBwZXJBZFN5c3RlbXMoKSB7CiAgICAg
            IHJldHVybiBbIiJdOwogICAgfQogICAgZ2V0V3JhcHBlckNyZWF0aXZlSWRzKCkgewogICAgICByZXR1cm4gWyIiXTsKICAg
            IH0KICAgIGlzTGluZWFyKCkgewogICAgICByZXR1cm4gdHJ1ZTsKICAgIH0KICAgIGlzU2tpcHBhYmxlKCkgewogICAgICBy
            ZXR1cm4gdHJ1ZTsKICAgIH0KICB9CgogIGNsYXNzIENvbXBhbmlvbkFkIHsKICAgIGdldEFkU2xvdElkKCkgewogICAgICBy
            ZXR1cm4gIiI7CiAgICB9CiAgICBnZXRDb250ZW50KCkgewogICAgICByZXR1cm4gIiI7CiAgICB9CiAgICBnZXRDb250ZW50
            VHlwZSgpIHsKICAgICAgcmV0dXJuICIiOwogICAgfQogICAgZ2V0SGVpZ2h0KCkgewogICAgICByZXR1cm4gMTsKICAgIH0K
            ICAgIGdldFdpZHRoKCkgewogICAgICByZXR1cm4gMTsKICAgIH0KICB9CgogIGNsYXNzIEFkRXJyb3IgewogICAgY29uc3Ry
            dWN0b3IodHlwZSwgY29kZSwgdmFzdCwgbWVzc2FnZSwgcmVxdWVzdCwgY29udGV4dCkgewogICAgICB0aGlzLmVycm9yQ29k
            ZSA9IGNvZGU7CiAgICAgIHRoaXMubWVzc2FnZSA9IG1lc3NhZ2U7CiAgICAgIHRoaXMudHlwZSA9IHR5cGU7CiAgICAgIHRo
            aXMuYWRzUmVxdWVzdCA9IHJlcXVlc3Q7CiAgICAgIHRoaXMudXNlclJlcXVlc3RDb250ZXh0ID0gY29udGV4dDsKICAgICAg
            dGhpcy52YXN0RXJyb3JDb2RlID0gdmFzdDsKICAgIH0KICAgIGdldEVycm9yQ29kZSgpIHsKICAgICAgcmV0dXJuIHRoaXMu
            ZXJyb3JDb2RlOwogICAgfQogICAgZ2V0SW5uZXJFcnJvcigpIHsKICAgICAgICByZXR1cm4gbnVsbDsKICAgIH0KICAgIGdl
            dE1lc3NhZ2UoKSB7CiAgICAgIHJldHVybiB0aGlzLm1lc3NhZ2U7CiAgICB9CiAgICBnZXRUeXBlKCkgewogICAgICByZXR1
            cm4gdGhpcy50eXBlOwogICAgfQogICAgZ2V0VmFzdEVycm9yQ29kZSgpIHsKICAgICAgcmV0dXJuIHRoaXMudmFzdEVycm9y
            Q29kZTsKICAgIH0KICAgIHRvU3RyaW5nKCkgewogICAgICByZXR1cm4gYEFkRXJyb3IgJHt0aGlzLmVycm9yQ29kZX06ICR7
            dGhpcy5tZXNzYWdlfWA7CiAgICB9CiAgfQogIEFkRXJyb3IuRXJyb3JDb2RlID0ge307CiAgQWRFcnJvci5UeXBlID0ge307
            CgogIGNvbnN0IGlzRW5nYWRnZXQgPSAoKSA9PiB7CiAgICB0cnkgewogICAgICBmb3IgKGNvbnN0IGN0eCBvZiBPYmplY3Qu
            dmFsdWVzKHdpbmRvdy52aWRpYmxlLl9nZXRDb250ZXh0cygpKSkgewogICAgICAgIGNvbnN0IHBsYXllciA9IGN0eC5nZXRQ
            bGF5ZXIoKTsKICAgICAgICBpZiAoIXBsYXllcikgeyBjb250aW51ZTt9CiAgICAgICAgY29uc3QgZGl2ID0gcGxheWVyLmRp
            djsKICAgICAgICBpZiAoIWRpdikgeyBjb250aW51ZTsgfQogICAgICAgIGlmIChkaXYuaW5uZXJIVE1MLmluY2x1ZGVzKCJ3
            d3cuZW5nYWRnZXQuY29tIikpIHsKICAgICAgICAgIHJldHVybiB0cnVlOwogICAgICAgIH0KICAgICAgfQogICAgfSBjYXRj
            aCB7CiAgICB9CiAgICByZXR1cm4gZmFsc2U7CiAgfTsKCiAgY29uc3QgY3VycmVudEFkID0gaXNFbmdhZGdldCgpID8gdW5k
            ZWZpbmVkIDogbmV3IEFkKCk7CgogIGNsYXNzIEFkRXZlbnQgewogICAgY29uc3RydWN0b3IodHlwZSkgewogICAgICB0aGlz
            LnR5cGUgPSB0eXBlOwogICAgfQogICAgZ2V0QWQoKSB7CiAgICAgIHJldHVybiBjdXJyZW50QWQ7CiAgICB9CiAgICBnZXRB
            ZERhdGEoKSB7CiAgICAgIHJldHVybiB7fTsKICAgIH0KICB9CiAgQWRFdmVudC5UeXBlID0gewogICAgQURfQlJFQUtfUkVB
            RFk6ICJhZEJyZWFrUmVhZHkiLAogICAgQURfQlVGRkVSSU5HOiAiYWRCdWZmZXJpbmciLAogICAgQURfQ0FOX1BMQVk6ICJh
            ZENhblBsYXkiLAogICAgQURfTUVUQURBVEE6ICJhZE1ldGFkYXRhIiwKICAgIEFEX1BST0dSRVNTOiAiYWRQcm9ncmVzcyIs
            CiAgICBBTExfQURTX0NPTVBMRVRFRDogImFsbEFkc0NvbXBsZXRlZCIsCiAgICBDTElDSzogImNsaWNrIiwKICAgIENPTVBM
            RVRFOiAiY29tcGxldGUiLAogICAgQ09OVEVOVF9QQVVTRV9SRVFVRVNURUQ6ICJjb250ZW50UGF1c2VSZXF1ZXN0ZWQiLAog
            ICAgQ09OVEVOVF9SRVNVTUVfUkVRVUVTVEVEOiAiY29udGVudFJlc3VtZVJlcXVlc3RlZCIsCiAgICBEVVJBVElPTl9DSEFO
            R0U6ICJkdXJhdGlvbkNoYW5nZSIsCiAgICBFWFBBTkRFRF9DSEFOR0VEOiAiZXhwYW5kZWRDaGFuZ2VkIiwKICAgIEZJUlNU
            X1FVQVJUSUxFOiAiZmlyc3RRdWFydGlsZSIsCiAgICBJTVBSRVNTSU9OOiAiaW1wcmVzc2lvbiIsCiAgICBJTlRFUkFDVElP
            TjogImludGVyYWN0aW9uIiwKICAgIExJTkVBUl9DSEFOR0U6ICJsaW5lYXJDaGFuZ2UiLAogICAgTElORUFSX0NIQU5HRUQ6
            ICJsaW5lYXJDaGFuZ2VkIiwKICAgIExPQURFRDogImxvYWRlZCIsCiAgICBMT0c6ICJsb2ciLAogICAgTUlEUE9JTlQ6ICJt
            aWRwb2ludCIsCiAgICBQQVVTRUQ6ICJwYXVzZSIsCiAgICBSRVNVTUVEOiAicmVzdW1lIiwKICAgIFNLSVBQQUJMRV9TVEFU
            RV9DSEFOR0VEOiAic2tpcHBhYmxlU3RhdGVDaGFuZ2VkIiwKICAgIFNLSVBQRUQ6ICJza2lwIiwKICAgIFNUQVJURUQ6ICJz
            dGFydCIsCiAgICBUSElSRF9RVUFSVElMRTogInRoaXJkUXVhcnRpbGUiLAogICAgVVNFUl9DTE9TRTogInVzZXJDbG9zZSIs
            CiAgICBWSURFT19DTElDS0VEOiAidmlkZW9DbGlja2VkIiwKICAgIFZJREVPX0lDT05fQ0xJQ0tFRDogInZpZGVvSWNvbkNs
            aWNrZWQiLAogICAgVklFV0FCTEVfSU1QUkVTU0lPTjogInZpZXdhYmxlX2ltcHJlc3Npb24iLAogICAgVk9MVU1FX0NIQU5H
            RUQ6ICJ2b2x1bWVDaGFuZ2UiLAogICAgVk9MVU1FX01VVEVEOiAibXV0ZSIsCiAgfTsKCiAgY2xhc3MgQWRFcnJvckV2ZW50
            IHsKICAgIGNvbnN0cnVjdG9yKGVycm9yKSB7CiAgICAgIHRoaXMudHlwZSA9ICJhZEVycm9yIjsKICAgICAgdGhpcy5lcnJv
            ciA9IGVycm9yOwogICAgfQogICAgZ2V0RXJyb3IoKSB7CiAgICAgIHJldHVybiB0aGlzLmVycm9yOwogICAgfQogICAgZ2V0
            VXNlclJlcXVlc3RDb250ZXh0KCkgewogICAgICByZXR1cm4gdGhpcy5lcnJvcj8udXNlclJlcXVlc3RDb250ZXh0IHx8IHt9
            OwogICAgfQogIH0KICBBZEVycm9yRXZlbnQuVHlwZSA9IHsKICAgIEFEX0VSUk9SOiAiYWRFcnJvciIsCiAgfTsKCiAgY29u
            c3QgbWFuYWdlciA9IG5ldyBBZHNNYW5hZ2VyKCk7CgogIGNsYXNzIEFkc01hbmFnZXJMb2FkZWRFdmVudCB7CiAgICBjb25z
            dHJ1Y3Rvcih0eXBlLCByZXF1ZXN0LCBjb250ZXh0KSB7CiAgICAgIHRoaXMudHlwZSA9IHR5cGU7CiAgICAgIHRoaXMuYWRz
            UmVxdWVzdCA9IHJlcXVlc3Q7CiAgICAgIHRoaXMudXNlclJlcXVlc3RDb250ZXh0ID0gY29udGV4dDsKICAgIH0KICAgIGdl
            dEFkc01hbmFnZXIoYywgc2V0dGluZ3MpIHsKICAgICAgaWYgKHNldHRpbmdzICYmIHNldHRpbmdzLmVuYWJsZVByZWxvYWRp
            bmcpIHsKICAgICAgICBtYW5hZ2VyLl9lbmFibGVQcmVsb2FkaW5nID0gdHJ1ZTsKICAgICAgfQogICAgICByZXR1cm4gbWFu
            YWdlcjsKICAgIH0KICAgIGdldFVzZXJSZXF1ZXN0Q29udGV4dCgpIHsKICAgICAgcmV0dXJuIHRoaXMudXNlclJlcXVlc3RD
            b250ZXh0IHx8IHt9OwogICAgfQogIH0KICBBZHNNYW5hZ2VyTG9hZGVkRXZlbnQuVHlwZSA9IHsKICAgIEFEU19NQU5BR0VS
            X0xPQURFRDogImFkc01hbmFnZXJMb2FkZWQiLAogIH07CgogIGNsYXNzIEN1c3RvbUNvbnRlbnRMb2FkZWRFdmVudCB7fQog
            IEN1c3RvbUNvbnRlbnRMb2FkZWRFdmVudC5UeXBlID0gewogICAgQ1VTVE9NX0NPTlRFTlRfTE9BREVEOiAiZGVwcmVjYXRl
            ZC1ldmVudCIsCiAgfTsKCiAgY2xhc3MgQ29tcGFuaW9uQWRTZWxlY3Rpb25TZXR0aW5ncyB7fQogIENvbXBhbmlvbkFkU2Vs
            ZWN0aW9uU2V0dGluZ3MuQ3JlYXRpdmVUeXBlID0gewogICAgQUxMOiAiQWxsIiwKICAgIEZMQVNIOiAiRmxhc2giLAogICAg
            SU1BR0U6ICJJbWFnZSIsCiAgfTsKICBDb21wYW5pb25BZFNlbGVjdGlvblNldHRpbmdzLlJlc291cmNlVHlwZSA9IHsKICAg
            IEFMTDogIkFsbCIsCiAgICBIVE1MOiAiSHRtbCIsCiAgICBJRlJBTUU6ICJJRnJhbWUiLAogICAgU1RBVElDOiAiU3RhdGlj
            IiwKICB9OwogIENvbXBhbmlvbkFkU2VsZWN0aW9uU2V0dGluZ3MuU2l6ZUNyaXRlcmlhID0gewogICAgSUdOT1JFOiAiSWdu
            b3JlU2l6ZSIsCiAgICBTRUxFQ1RfRVhBQ1RfTUFUQ0g6ICJTZWxlY3RFeGFjdE1hdGNoIiwKICAgIFNFTEVDVF9ORUFSX01B
            VENIOiAiU2VsZWN0TmVhck1hdGNoIiwKICB9OwoKICBjbGFzcyBBZEN1ZVBvaW50cyB7CiAgICBnZXRDdWVQb2ludHMoKSB7
            CiAgICAgIHJldHVybiBbXTsKICAgIH0KICB9CgogIGNsYXNzIEFkUHJvZ3Jlc3NEYXRhIHt9CgogIGNsYXNzIFVuaXZlcnNh
            bEFkSWRJbmZvIHsKICAgIGdldEFkSWRSZWdpc3RyeSgpIHsKICAgICAgcmV0dXJuICIiOwogICAgfQogICAgZ2V0QWRJZFZh
            bHVlKCkgewogICAgICByZXR1cm4gIiI7CiAgICB9CiAgfQoKICBPYmplY3QuYXNzaWduKGltYSwgewogICAgQWRDdWVQb2lu
            dHMsCiAgICBBZERpc3BsYXlDb250YWluZXIsCiAgICBBZEVycm9yLAogICAgQWRFcnJvckV2ZW50LAogICAgQWRFdmVudCwK
            ICAgIEFkUG9kSW5mbywKICAgIEFkUHJvZ3Jlc3NEYXRhLAogICAgQWRzTG9hZGVyLAogICAgQWRzTWFuYWdlcjogbWFuYWdl
            ciwKICAgIEFkc01hbmFnZXJMb2FkZWRFdmVudCwKICAgIEFkc1JlbmRlcmluZ1NldHRpbmdzLAogICAgQWRzUmVxdWVzdCwK
            ICAgIENvbXBhbmlvbkFkLAogICAgQ29tcGFuaW9uQWRTZWxlY3Rpb25TZXR0aW5ncywKICAgIEN1c3RvbUNvbnRlbnRMb2Fk
            ZWRFdmVudCwKICAgIGdwdFByb3h5SW5zdGFuY2U6IHt9LAogICAgSW1hU2RrU2V0dGluZ3MsCiAgICBPbWlkQWNjZXNzTW9k
            ZTogewogICAgICBET01BSU46ICJkb21haW4iLAogICAgICBGVUxMOiAiZnVsbCIsCiAgICAgIExJTUlURUQ6ICJsaW1pdGVk
            IiwKICAgIH0sCiAgICBPbWlkVmVyaWZpY2F0aW9uVmVuZG9yOiB7CiAgICAgIDE6ICJPVEhFUiIsCiAgICAgIDI6ICJHT09H
            TEUiLAogICAgICBHT09HTEU6IDIsCiAgICAgIE9USEVSOiAxCiAgICB9LAogICAgc2V0dGluZ3M6IG5ldyBJbWFTZGtTZXR0
            aW5ncygpLAogICAgVWlFbGVtZW50czogewogICAgICBBRF9BVFRSSUJVVElPTjogImFkQXR0cmlidXRpb24iLAogICAgICBD
            T1VOVERPV046ICJjb3VudGRvd24iLAogICAgfSwKICAgIFVuaXZlcnNhbEFkSWRJbmZvLAogICAgVkVSU0lPTiwKICAgIFZp
            ZXdNb2RlOiB7CiAgICAgIEZVTExTQ1JFRU46ICJmdWxsc2NyZWVuIiwKICAgICAgTk9STUFMOiAibm9ybWFsIiwKICAgIH0s
            CiAgfSk7CgogIGlmICghd2luZG93Lmdvb2dsZSkgewogICAgd2luZG93Lmdvb2dsZSA9IHt9OwogIH0KCiAgd2luZG93Lmdv
            b2dsZS5pbWEgPSBpbWE7Cn0KCi8qCmFkLmRvdWJsZWNsaWNrLm5ldCBiaWQuZy5kb3VibGVjbGljay5uZXQgZ2dwaHQuY29t
            IGdvb2dsZS5jby51ayBnb29nbGUuY29tCmdvb2dsZWFkcy5nLmRvdWJsZWNsaWNrLm5ldCBnb29nbGVhZHM0LmcuZG91Ymxl
            Y2xpY2submV0IGdvb2dsZWFkc2VydmljZXMuY29tCmdvb2dsZXN5bmRpY2F0aW9uLmNvbSBnb29nbGV1c2VyY29udGVudC5j
            b20gZ3N0YXRpYy5jb20gZ3Z0MS5jb20gcHJvZC5nb29nbGUuY29tCnB1YmFkcy5nLmRvdWJsZWNsaWNrLm5ldCBzMC4ybWRu
            Lm5ldCBzdGF0aWMuZG91YmxlY2xpY2submV0CnN1cnZleXMuZy5kb3VibGVjbGljay5uZXQgeW91dHViZS5jb20geXRpbWcu
            Y29tCiovCg==
            """
        ),
        RedirectResource(
            name: "googlesyndication_adsbygoogle.js",
            mimeType: "text/javascript",
            base64: """
            LyoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
            KioqKioqKioKCiAgICB1QmxvY2sgT3JpZ2luIC0gYSBicm93c2VyIGV4dGVuc2lvbiB0byBibG9jayByZXF1ZXN0cy4KICAg
            IENvcHlyaWdodCAoQykgMjAxOS1wcmVzZW50IFJheW1vbmQgSGlsbAoKICAgIFRoaXMgcHJvZ3JhbSBpcyBmcmVlIHNvZnR3
            YXJlOiB5b3UgY2FuIHJlZGlzdHJpYnV0ZSBpdCBhbmQvb3IgbW9kaWZ5CiAgICBpdCB1bmRlciB0aGUgdGVybXMgb2YgdGhl
            IEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGFzIHB1Ymxpc2hlZCBieQogICAgdGhlIEZyZWUgU29mdHdhcmUgRm91bmRh
            dGlvbiwgZWl0aGVyIHZlcnNpb24gMyBvZiB0aGUgTGljZW5zZSwgb3IKICAgIChhdCB5b3VyIG9wdGlvbikgYW55IGxhdGVy
            IHZlcnNpb24uCgogICAgVGhpcyBwcm9ncmFtIGlzIGRpc3RyaWJ1dGVkIGluIHRoZSBob3BlIHRoYXQgaXQgd2lsbCBiZSB1
            c2VmdWwsCiAgICBidXQgV0lUSE9VVCBBTlkgV0FSUkFOVFk7IHdpdGhvdXQgZXZlbiB0aGUgaW1wbGllZCB3YXJyYW50eSBv
            ZgogICAgTUVSQ0hBTlRBQklMSVRZIG9yIEZJVE5FU1MgRk9SIEEgUEFSVElDVUxBUiBQVVJQT1NFLiAgU2VlIHRoZQogICAg
            R05VIEdlbmVyYWwgUHVibGljIExpY2Vuc2UgZm9yIG1vcmUgZGV0YWlscy4KCiAgICBZb3Ugc2hvdWxkIGhhdmUgcmVjZWl2
            ZWQgYSBjb3B5IG9mIHRoZSBHTlUgR2VuZXJhbCBQdWJsaWMgTGljZW5zZQogICAgYWxvbmcgd2l0aCB0aGlzIHByb2dyYW0u
            ICBJZiBub3QsIHNlZSB7aHR0cDovL3d3dy5nbnUub3JnL2xpY2Vuc2VzL30uCgogICAgSG9tZTogaHR0cHM6Ly9naXRodWIu
            Y29tL2dvcmhpbGwvdUJsb2NrCiovCgooZnVuY3Rpb24oKSB7CiAgICBzZWxmLmFkc2J5Z29vZ2xlID0gc2VsZi5hZHNieWdv
            b2dsZSB8fCB7CiAgICAgICAgbG9hZGVkOiB0cnVlLAogICAgICAgIHB1c2g6IGZ1bmN0aW9uKCkgewogICAgICAgICAgICA7
            CiAgICAgICAgfQogICAgfTsKICAgIGxldCBhZENvdW50ID0gMTsKICAgIGNvbnN0IHNldHVwQWQgPSAocGxhY2Vob2xkZXIp
            ID0+IHsKICAgICAgICBjb25zdCBmciA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2lmcmFtZScpOwogICAgICAgIGZyLmlk
            ID0gYGFzd2lmdF8ke2FkQ291bnR9YDsKICAgICAgICBmci5zZXRBdHRyaWJ1dGUoJ25hbWUnLCBmci5pZCk7CiAgICAgICAg
            YWRDb3VudCArPSAxOwogICAgICAgIHBsYWNlaG9sZGVyLmRhdGFzZXQuYWRzYnlnb29nbGVTdGF0dXMgPSAnbG9hZGluZyc7
            CiAgICAgICAgcGxhY2Vob2xkZXIuZGF0YXNldC5hZFN0YXR1cyA9ICdsb2FkaW5nJzsKICAgICAgICBwbGFjZWhvbGRlci5h
            cHBlbmRDaGlsZChmcik7CiAgICAgICAgZnIuYWRkRXZlbnRMaXN0ZW5lcignbG9hZCcsICggKSA9PiB7CiAgICAgICAgICAg
            IHBsYWNlaG9sZGVyLmRhdGFzZXQuYWRzYnlnb29nbGVTdGF0dXMgPSAnZG9uZSc7CiAgICAgICAgICAgIHBsYWNlaG9sZGVy
            LmRhdGFzZXQuYWRTdGF0dXMgPSAnZmlsbGVkJzsKICAgICAgICAgICAgZnIuZGF0YXNldC5sb2FkQ29tcGxldGUgPSAndHJ1
            ZSc7CiAgICAgICAgfSwgeyBvbmNlOiB0cnVlIH0pOwogICAgICAgIGZyLmNvbnRlbnRXaW5kb3cubG9jYXRpb24gPSAnZGF0
            YTp0ZXh0L2h0bWw7Y2hhcnNldD11dGYtODtiYXNlNjQsUENGRVQwTlVXVkJGSUdoMGJXdytEUW84YUhSdGJENE5DaUFnSUNB
            OGFHVmhaRDQ4ZEdsMGJHVStQQzkwYVhSc1pUNDhMMmhsWVdRK0RRb2dJQ0FnUEdKdlpIaytQQzlpYjJSNVBnMEtQQzlvZEcx
            c1BnPT0nOwogICAgfTsKICAgIGNvbnN0IHByb2Nlc3MgPSAoICkgPT4gewogICAgICAgIGNvbnN0IHBocyA9IGRvY3VtZW50
            LnF1ZXJ5U2VsZWN0b3JBbGwoJy5hZHNieWdvb2dsZTpub3QoW2RhdGEtYWQtc3RhdHVzXVtkYXRhLWFkc2J5Z29vZ2xlLXN0
            YXR1c10pJyk7CiAgICAgICAgZm9yICggY29uc3QgcGggb2YgcGhzICkgewogICAgICAgICAgICBzZXR1cEFkKHBoKTsKICAg
            ICAgICB9CiAgICB9OwogICAgcHJvY2VzcygpOwoKICAgIGxldCBvYnNlcnZlciA9IG5ldyBNdXRhdGlvbk9ic2VydmVyKCgg
            KSA9PiB7CiAgICAgICAgaWYgKCBwcm9jZXNzLnRpbWVyICE9PSB1bmRlZmluZWQgKSB7IHJldHVybjsgfQogICAgICAgIHBy
            b2Nlc3MudGltZXIgPSBzZWxmLnJlcXVlc3RBbmltYXRpb25GcmFtZSgoICkgPT4gewogICAgICAgICAgICBwcm9jZXNzLnRp
            bWVyID0gdW5kZWZpbmVkOwogICAgICAgICAgICBwcm9jZXNzKCk7CiAgICAgICAgfSwpOwogICAgfSk7CiAgICBvYnNlcnZl
            ci5vYnNlcnZlKGRvY3VtZW50LCB7CiAgICAgICAgYXR0cmlidXRlczogdHJ1ZSwKICAgICAgICBhdHRyaWJ1dGVGaWx0ZXI6
            IFsgJ2NsYXNzJyBdLAogICAgICAgIGNoaWxkTGlzdDogdHJ1ZSwKICAgICAgICBzdWJ0cmVlOiB0cnVlLAogICAgfSk7Cgog
            ICAgc2V0VGltZW91dCgoICkgPT4gewogICAgICAgIG9ic2VydmVyLmRpc2Nvbm5lY3QoKTsKICAgICAgICBvYnNlcnZlciA9
            IHVuZGVmaW5lZDsKICAgIH0sIDIwMDAwKTsKfSkoKTsKCi8qCnBhZ2VhZDIuZ29vZ2xlc3luZGljYXRpb24uY29tL3BhZ2Vh
            ZC9qcy9hZHNieWdvb2dsZS5qcyxhZHNieWdvb2dsZS1wbGFjZWhvbGRlcixhZHNieWdvb2dsZVN0YXR1cyxnb29nbGVfYWRf
            Y2hhbm5lbCxnb29nbGVfYWRfY2xpZW50LGdvb2dsZV9hZF9mb3JtYXQsZ29vZ2xlX2FkX2ZyZXF1ZW5jeV9oaW50LGdvb2ds
            ZV9hZF9oZWlnaHQsZ29vZ2xlX2FkX2hvc3QsZ29vZ2xlX2FkX2hvc3RfY2hhbm5lbCxnb29nbGVfYWRfbW9kaWZpY2F0aW9u
            cyxnb29nbGVfYWRfcmVnaW9uLGdvb2dsZV9hZF9yZXNpemFibGUsZ29vZ2xlX2FkX3Jlc2l6ZSxnb29nbGVfYWRfc2VjdGlv
            bixnb29nbGVfYWRfc2VtYW50aWNfYXJlYSxnb29nbGVfYWRfd2lkdGgsZ29vZ2xlX2FkYnJlYWtfdGVzdCxnb29nbGVfYWRz
            X2ZyYW1lLGdvb2dsZV9hZHNfaWZyYW1lLGdvb2dsZV9hZHRlc3QsZ29vZ2xlX2FkbW9iX2ludGVyc3RpdGlhbF9zbG90LGdv
            b2dsZV9hZG1vYl9yZXdhcmRlZF9zbG90LGdvb2dsZV9hZG1vYl9hZHNfb25seSxnb29nbGUtYWRzZW5zZS1wbGF0Zm9ybS1h
            Y2NvdW50LGdvb2dsZV9hZHNlbnNlX3NldHRpbmdzLGdvb2dsZV9hbWFfY29uZmlnLGdvb2dsZS1hbWEtb3JkZXItYXNzdXJh
            bmNlLGdvb2dsZV9hbWFfc2V0dGluZ3MsZ29vZ2xlX2FtYV9zdGF0ZSxnb29nbGVfYXBsdGxhZCxnb29nbGVfYXVkaW9fc2Vu
            c2UsZ29vZ2xlLWF1dG8tcGxhY2VkLXJlYWQtYWxvdWQtcGxheWVyLXJlc2VydmVkLGdvb2dsZV9kZWJ1Z19wYXJhbXMsZ29v
            Z2xlX2Z1bGxfd2lkdGhfcmVzcG9uc2l2ZSxnb29nbGVfZnVsbF93aWR0aF9yZXNwb25zaXZlX2FsbG93ZWQsZ29vZ2xlX2lt
            YWdlX3JlcXVlc3RzLGdvb2dsZV9qc19lcnJvcnMsZ29vZ2xlX2pzX3JlcG9ydGluZ19xdWV1ZSxnb29nbGVfbG9hZGVyX2Zl
            YXR1cmVzX3VzZWQsZ29vZ2xlX2xscCxnb29nbGVfbG9nZ2luZ19xdWV1ZSxnb29nbGVfbWF4X2FkX2NvbnRlbnRfcmF0aW5n
            LGdvb2dsZV9tZWFzdXJlX2pzX3RpbWluZyxnb29nbGVfbWxfcmFuayxnb29nbGVfb3ZlcmxheXMsZ29vZ2xlX292ZXJyaWRl
            X2Zvcm1hdCxnb29nbGVfcGFja2FnZSxnb29nbGVfcGFnZV91cmwsZ29vZ2xlX3BlcnNpc3RlbnRfc3RhdGVfYXN5bmMsZ29v
            Z2xlX3BnYl9yZWFjdGl2ZSxnb29nbGVfcGxhY2VtZW50X2lkLGdvb2dsZV9wcmV2X2FkX2Zvcm1hdHNfYnlfcmVnaW9uLGdv
            b2dsZV9wcmV2X2FkX3Nsb3RuYW1lc19ieV9yZWdpb24sZ29vZ2xlX3JlYWN0aXZlX2FkX2Zvcm1hdCxnb29nbGVfcmVhY3Rp
            dmVfYWRzX2dsb2JhbF9zdGF0ZSxnb29nbGVfcmVzaXppbmdfaGVpZ2h0LGdvb2dsZV9yZXNpemluZ193aWR0aCxnb29nbGVf
            cmVzcG9uc2l2ZV9hdXRvX2Zvcm1hdCxnb29nbGVfcmVzcG9uc2l2ZV9kdW1teV9hZCxnb29nbGVfcmVzcG9uc2l2ZV9mb3Jt
            YXRzLGdvb2dsZV9yZXN0cmljdF9kYXRhX3Byb2Nlc3NpbmcsZ29vZ2xlX3J1bV90YXNrX2lkX2NvdW50ZXIsZ29vZ2xlX3Nh
            ZmVfZm9yX3Jlc3BvbnNpdmVfb3ZlcnJpZGUsZ29vZ2xlX3NoYWRvd19tb2RlLGdvb2dsZV9zcnQsZ29vZ2xlX3RhZ19mb3Jf
            dW5kZXJfYWdlX29mX2NvbnNlbnQsZ29vZ2xlX3RhZ19vcmlnaW4sZ29vZ2xlX3RhZ19wYXJ0bmVyLGdvb2dsZV90cmFmZmlj
            X3NvdXJjZSxnb29nbGVfdW5pcXVlX2lkLGdvb2dsZXRhZwoqLwo=
            """
        ),
        RedirectResource(
            name: "googletagservices_gpt.js",
            mimeType: "text/javascript",
            base64: """
            LyoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
            KioqKioqKioKCiAgICB1QmxvY2sgT3JpZ2luIC0gYSBicm93c2VyIGV4dGVuc2lvbiB0byBibG9jayByZXF1ZXN0cy4KICAg
            IENvcHlyaWdodCAoQykgMjAxOS1wcmVzZW50IFJheW1vbmQgSGlsbAoKICAgIFRoaXMgcHJvZ3JhbSBpcyBmcmVlIHNvZnR3
            YXJlOiB5b3UgY2FuIHJlZGlzdHJpYnV0ZSBpdCBhbmQvb3IgbW9kaWZ5CiAgICBpdCB1bmRlciB0aGUgdGVybXMgb2YgdGhl
            IEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGFzIHB1Ymxpc2hlZCBieQogICAgdGhlIEZyZWUgU29mdHdhcmUgRm91bmRh
            dGlvbiwgZWl0aGVyIHZlcnNpb24gMyBvZiB0aGUgTGljZW5zZSwgb3IKICAgIChhdCB5b3VyIG9wdGlvbikgYW55IGxhdGVy
            IHZlcnNpb24uCgogICAgVGhpcyBwcm9ncmFtIGlzIGRpc3RyaWJ1dGVkIGluIHRoZSBob3BlIHRoYXQgaXQgd2lsbCBiZSB1
            c2VmdWwsCiAgICBidXQgV0lUSE9VVCBBTlkgV0FSUkFOVFk7IHdpdGhvdXQgZXZlbiB0aGUgaW1wbGllZCB3YXJyYW50eSBv
            ZgogICAgTUVSQ0hBTlRBQklMSVRZIG9yIEZJVE5FU1MgRk9SIEEgUEFSVElDVUxBUiBQVVJQT1NFLiAgU2VlIHRoZQogICAg
            R05VIEdlbmVyYWwgUHVibGljIExpY2Vuc2UgZm9yIG1vcmUgZGV0YWlscy4KCiAgICBZb3Ugc2hvdWxkIGhhdmUgcmVjZWl2
            ZWQgYSBjb3B5IG9mIHRoZSBHTlUgR2VuZXJhbCBQdWJsaWMgTGljZW5zZQogICAgYWxvbmcgd2l0aCB0aGlzIHByb2dyYW0u
            ICBJZiBub3QsIHNlZSB7aHR0cDovL3d3dy5nbnUub3JnL2xpY2Vuc2VzL30uCgogICAgSG9tZTogaHR0cHM6Ly9naXRodWIu
            Y29tL2dvcmhpbGwvdUJsb2NrCiovCgooZnVuY3Rpb24oKSB7CiAgICAndXNlIHN0cmljdCc7CiAgICAvLyBodHRwczovL2Rl
            dmVsb3BlcnMuZ29vZ2xlLmNvbS9kb3VibGVjbGljay1ncHQvcmVmZXJlbmNlCiAgICBjb25zdCBub29wZm4gPSBmdW5jdGlv
            bigpIHsKICAgIH0uYmluZCgpOwogICAgY29uc3Qgbm9vcHRoaXNmbiA9IGZ1bmN0aW9uKCkgewogICAgICAgIHJldHVybiB0
            aGlzOwogICAgfTsKICAgIGNvbnN0IG5vb3BudWxsZm4gPSBmdW5jdGlvbigpIHsKICAgICAgICByZXR1cm4gbnVsbDsKICAg
            IH07CiAgICBjb25zdCBub29wYXJyYXlmbiA9IGZ1bmN0aW9uKCkgewogICAgICAgIHJldHVybiBbXTsKICAgIH07CiAgICBj
            b25zdCBub29wc3RyZm4gPSBmdW5jdGlvbigpIHsKICAgICAgICByZXR1cm4gJyc7CiAgICB9OwogICAgLy8KICAgIGNvbnN0
            IGNvbXBhbmlvbkFkc1NlcnZpY2UgPSB7CiAgICAgICAgYWRkRXZlbnRMaXN0ZW5lcjogbm9vcHRoaXNmbiwKICAgICAgICBl
            bmFibGVTeW5jTG9hZGluZzogbm9vcGZuLAogICAgICAgIHNldFJlZnJlc2hVbmZpbGxlZFNsb3RzOiBub29wZm4KICAgIH07
            CiAgICBjb25zdCBjb250ZW50U2VydmljZSA9IHsKICAgICAgICBhZGRFdmVudExpc3RlbmVyOiBub29wdGhpc2ZuLAogICAg
            ICAgIHNldENvbnRlbnQ6IG5vb3BmbgogICAgfTsKICAgIGNvbnN0IFBhc3NiYWNrU2xvdCA9IGZ1bmN0aW9uKCkgewogICAg
            fTsKICAgIGxldCBwID0gUGFzc2JhY2tTbG90LnByb3RvdHlwZTsKICAgIHAuZGlzcGxheSA9IG5vb3BmbjsKICAgIHAuZ2V0
            ID0gbm9vcG51bGxmbjsKICAgIHAuc2V0ID0gbm9vcHRoaXNmbjsKICAgIHAuc2V0Q2xpY2tVcmwgPSBub29wdGhpc2ZuOwog
            ICAgcC5zZXRUYWdGb3JDaGlsZERpcmVjdGVkVHJlYXRtZW50ID0gbm9vcHRoaXNmbjsKICAgIHAuc2V0VGFyZ2V0aW5nID0g
            bm9vcHRoaXNmbjsKICAgIHAudXBkYXRlVGFyZ2V0aW5nRnJvbU1hcCA9IG5vb3B0aGlzZm47CiAgICBjb25zdCBwdWJBZHNT
            ZXJ2aWNlID0gewogICAgICAgIGFkZEV2ZW50TGlzdGVuZXI6IG5vb3B0aGlzZm4sCiAgICAgICAgY2xlYXI6IG5vb3BmbiwK
            ICAgICAgICBjbGVhckNhdGVnb3J5RXhjbHVzaW9uczogbm9vcHRoaXNmbiwKICAgICAgICBjbGVhclRhZ0ZvckNoaWxkRGly
            ZWN0ZWRUcmVhdG1lbnQ6IG5vb3B0aGlzZm4sCiAgICAgICAgY2xlYXJUYXJnZXRpbmc6IG5vb3B0aGlzZm4sCiAgICAgICAg
            Y29sbGFwc2VFbXB0eURpdnM6IG5vb3BmbiwKICAgICAgICBkZWZpbmVPdXRPZlBhZ2VQYXNzYmFjazogZnVuY3Rpb24oKSB7
            IHJldHVybiBuZXcgUGFzc2JhY2tTbG90KCk7IH0sCiAgICAgICAgZGVmaW5lUGFzc2JhY2s6IGZ1bmN0aW9uKCkgeyByZXR1
            cm4gbmV3IFBhc3NiYWNrU2xvdCgpOyB9LAogICAgICAgIGRpc2FibGVJbml0aWFsTG9hZDogbm9vcGZuLAogICAgICAgIGRp
            c3BsYXk6IG5vb3BmbiwKICAgICAgICBlbmFibGVBc3luY1JlbmRlcmluZzogbm9vcGZuLAogICAgICAgIGVuYWJsZUxhenlM
            b2FkOiBub29wZm4sCiAgICAgICAgZW5hYmxlU2luZ2xlUmVxdWVzdDogbm9vcGZuLAogICAgICAgIGVuYWJsZVN5bmNSZW5k
            ZXJpbmc6IG5vb3BmbiwKICAgICAgICBlbmFibGVWaWRlb0Fkczogbm9vcGZuLAogICAgICAgIGdldDogbm9vcG51bGxmbiwK
            ICAgICAgICBnZXRBdHRyaWJ1dGVLZXlzOiBub29wYXJyYXlmbiwKICAgICAgICBnZXRUYXJnZXRpbmc6IG5vb3BhcnJheWZu
            LAogICAgICAgIGdldFRhcmdldGluZ0tleXM6IG5vb3BhcnJheWZuLAogICAgICAgIGdldFNsb3RzOiBub29wYXJyYXlmbiwK
            ICAgICAgICByZWZyZXNoOiBub29wZm4sCiAgICAgICAgcmVtb3ZlRXZlbnRMaXN0ZW5lcjogbm9vcGZuLAogICAgICAgIHNl
            dDogbm9vcHRoaXNmbiwKICAgICAgICBzZXRDYXRlZ29yeUV4Y2x1c2lvbjogbm9vcHRoaXNmbiwKICAgICAgICBzZXRDZW50
            ZXJpbmc6IG5vb3BmbiwKICAgICAgICBzZXRDb29raWVPcHRpb25zOiBub29wdGhpc2ZuLAogICAgICAgIHNldEZvcmNlU2Fm
            ZUZyYW1lOiBub29wdGhpc2ZuLAogICAgICAgIHNldExvY2F0aW9uOiBub29wdGhpc2ZuLAogICAgICAgIHNldFB1Ymxpc2hl
            clByb3ZpZGVkSWQ6IG5vb3B0aGlzZm4sCiAgICAgICAgc2V0UHJpdmFjeVNldHRpbmdzOiBub29wdGhpc2ZuLAogICAgICAg
            IHNldFJlcXVlc3ROb25QZXJzb25hbGl6ZWRBZHM6IG5vb3B0aGlzZm4sCiAgICAgICAgc2V0U2FmZUZyYW1lQ29uZmlnOiBu
            b29wdGhpc2ZuLAogICAgICAgIHNldFRhZ0ZvckNoaWxkRGlyZWN0ZWRUcmVhdG1lbnQ6IG5vb3B0aGlzZm4sCiAgICAgICAg
            c2V0VGFyZ2V0aW5nOiBub29wdGhpc2ZuLAogICAgICAgIHNldFZpZGVvQ29udGVudDogbm9vcHRoaXNmbiwKICAgICAgICB1
            cGRhdGVDb3JyZWxhdG9yOiBub29wZm4KICAgIH07CiAgICBjb25zdCBTaXplTWFwcGluZ0J1aWxkZXIgPSBmdW5jdGlvbigp
            IHsKICAgIH07CiAgICBwID0gU2l6ZU1hcHBpbmdCdWlsZGVyLnByb3RvdHlwZTsKICAgIHAuYWRkU2l6ZSA9IG5vb3B0aGlz
            Zm47CiAgICBwLmJ1aWxkID0gbm9vcG51bGxmbjsKICAgIGNvbnN0IFNsb3QgPSBmdW5jdGlvbigpIHsKICAgIH07CiAgICBw
            ID0gU2xvdC5wcm90b3R5cGU7CiAgICBwLmFkZFNlcnZpY2UgPSBub29wdGhpc2ZuOwogICAgcC5jbGVhckNhdGVnb3J5RXhj
            bHVzaW9ucyA9IG5vb3B0aGlzZm47CiAgICBwLmNsZWFyVGFyZ2V0aW5nID0gbm9vcHRoaXNmbjsKICAgIHAuZGVmaW5lU2l6
            ZU1hcHBpbmcgPSBub29wdGhpc2ZuOwogICAgcC5nZXQgPSBub29wbnVsbGZuOwogICAgcC5nZXRBZFVuaXRQYXRoID0gbm9v
            cGFycmF5Zm47CiAgICBwLmdldEF0dHJpYnV0ZUtleXMgPSBub29wYXJyYXlmbjsKICAgIHAuZ2V0Q2F0ZWdvcnlFeGNsdXNp
            b25zID0gbm9vcGFycmF5Zm47CiAgICBwLmdldERvbUlkID0gbm9vcHN0cmZuOwogICAgcC5nZXRSZXNwb25zZUluZm9ybWF0
            aW9uID0gbm9vcG51bGxmbjsKICAgIHAuZ2V0U2xvdEVsZW1lbnRJZCA9IG5vb3BzdHJmbjsKICAgIHAuZ2V0U2xvdElkID0g
            bm9vcHRoaXNmbjsKICAgIHAuZ2V0VGFyZ2V0aW5nID0gbm9vcGFycmF5Zm47CiAgICBwLmdldFRhcmdldGluZ0tleXMgPSBu
            b29wYXJyYXlmbjsKICAgIHAuc2V0ID0gbm9vcHRoaXNmbjsKICAgIHAuc2V0Q2F0ZWdvcnlFeGNsdXNpb24gPSBub29wdGhp
            c2ZuOwogICAgcC5zZXRDbGlja1VybCA9IG5vb3B0aGlzZm47CiAgICBwLnNldENvbGxhcHNlRW1wdHlEaXYgPSBub29wdGhp
            c2ZuOwogICAgcC5zZXRUYXJnZXRpbmcgPSBub29wdGhpc2ZuOwogICAgcC51cGRhdGVUYXJnZXRpbmdGcm9tTWFwID0gbm9v
            cHRoaXNmbjsKICAgIC8vCiAgICBjb25zdCBncHQgPSB3aW5kb3cuZ29vZ2xldGFnIHx8IHt9OwogICAgY29uc3QgY21kID0g
            Z3B0LmNtZCB8fCBbXTsKICAgIGdwdC5hcGlSZWFkeSA9IHRydWU7CiAgICBncHQuY21kID0gW107CiAgICBncHQuY21kLnB1
            c2ggPSBmdW5jdGlvbihhKSB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgYSgpOwogICAgICAgIH0gY2F0Y2ggKGV4KSB7
            CiAgICAgICAgfQogICAgICAgIHJldHVybiAxOwogICAgfTsKICAgIGdwdC5jb21wYW5pb25BZHMgPSBmdW5jdGlvbigpIHsg
            cmV0dXJuIGNvbXBhbmlvbkFkc1NlcnZpY2U7IH07CiAgICBncHQuY29udGVudCA9IGZ1bmN0aW9uKCkgeyByZXR1cm4gY29u
            dGVudFNlcnZpY2U7IH07CiAgICBncHQuZGVmaW5lT3V0T2ZQYWdlU2xvdCA9IGZ1bmN0aW9uKCkgeyByZXR1cm4gbmV3IFNs
            b3QoKTsgfTsKICAgIGdwdC5kZWZpbmVTbG90ID0gZnVuY3Rpb24oKSB7IHJldHVybiBuZXcgU2xvdCgpOyB9OwogICAgZ3B0
            LmRlc3Ryb3lTbG90cyA9IG5vb3BmbjsKICAgIGdwdC5kaXNhYmxlUHVibGlzaGVyQ29uc29sZSA9IG5vb3BmbjsKICAgIGdw
            dC5kaXNwbGF5ID0gbm9vcGZuOwogICAgZ3B0LmVuYWJsZVNlcnZpY2VzID0gbm9vcGZuOwogICAgZ3B0LmdldFZlcnNpb24g
            PSBub29wc3RyZm47CiAgICBncHQucHViYWRzID0gZnVuY3Rpb24oKSB7IHJldHVybiBwdWJBZHNTZXJ2aWNlOyB9OwogICAg
            Z3B0LnB1YmFkc1JlYWR5ID0gdHJ1ZTsKICAgIGdwdC5zZXRBZElmcmFtZVRpdGxlID0gbm9vcGZuOwogICAgZ3B0LnNpemVN
            YXBwaW5nID0gZnVuY3Rpb24oKSB7IHJldHVybiBuZXcgU2l6ZU1hcHBpbmdCdWlsZGVyKCk7IH07CiAgICB3aW5kb3cuZ29v
            Z2xldGFnID0gZ3B0OwogICAgd2hpbGUgKCBjbWQubGVuZ3RoICE9PSAwICkgewogICAgICAgIGdwdC5jbWQucHVzaChjbWQu
            c2hpZnQoKSk7CiAgICB9Cn0pKCk7Cg==
            """
        ),
        RedirectResource(
            name: "hd-main.js",
            mimeType: "text/javascript",
            base64: """
            LyoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
            KioqKioqKioKCiAgICB1QmxvY2sgT3JpZ2luIC0gYSBicm93c2VyIGV4dGVuc2lvbiB0byBibG9jayByZXF1ZXN0cy4KICAg
            IENvcHlyaWdodCAoQykgMjAxOS1wcmVzZW50IFJheW1vbmQgSGlsbAoKICAgIFRoaXMgcHJvZ3JhbSBpcyBmcmVlIHNvZnR3
            YXJlOiB5b3UgY2FuIHJlZGlzdHJpYnV0ZSBpdCBhbmQvb3IgbW9kaWZ5CiAgICBpdCB1bmRlciB0aGUgdGVybXMgb2YgdGhl
            IEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGFzIHB1Ymxpc2hlZCBieQogICAgdGhlIEZyZWUgU29mdHdhcmUgRm91bmRh
            dGlvbiwgZWl0aGVyIHZlcnNpb24gMyBvZiB0aGUgTGljZW5zZSwgb3IKICAgIChhdCB5b3VyIG9wdGlvbikgYW55IGxhdGVy
            IHZlcnNpb24uCgogICAgVGhpcyBwcm9ncmFtIGlzIGRpc3RyaWJ1dGVkIGluIHRoZSBob3BlIHRoYXQgaXQgd2lsbCBiZSB1
            c2VmdWwsCiAgICBidXQgV0lUSE9VVCBBTlkgV0FSUkFOVFk7IHdpdGhvdXQgZXZlbiB0aGUgaW1wbGllZCB3YXJyYW50eSBv
            ZgogICAgTUVSQ0hBTlRBQklMSVRZIG9yIEZJVE5FU1MgRk9SIEEgUEFSVElDVUxBUiBQVVJQT1NFLiAgU2VlIHRoZQogICAg
            R05VIEdlbmVyYWwgUHVibGljIExpY2Vuc2UgZm9yIG1vcmUgZGV0YWlscy4KCiAgICBZb3Ugc2hvdWxkIGhhdmUgcmVjZWl2
            ZWQgYSBjb3B5IG9mIHRoZSBHTlUgR2VuZXJhbCBQdWJsaWMgTGljZW5zZQogICAgYWxvbmcgd2l0aCB0aGlzIHByb2dyYW0u
            ICBJZiBub3QsIHNlZSB7aHR0cDovL3d3dy5nbnUub3JnL2xpY2Vuc2VzL30uCgogICAgSG9tZTogaHR0cHM6Ly9naXRodWIu
            Y29tL2dvcmhpbGwvdUJsb2NrCiovCgooZnVuY3Rpb24oKSB7CiAgICAndXNlIHN0cmljdCc7CiAgICBjb25zdCBsID0ge307
            CiAgICBjb25zdCBub29wZm4gPSBmdW5jdGlvbigpIHsKICAgIH07CiAgICBjb25zdCBwcm9wcyA9IFsKICAgICAgICAiJGoi
            LCJBZCIsIkJkIiwiQ2QiLCJEZCIsIkVkIiwiRmQiLCJHZCIsIkhkIiwiSWQiLCJKZCIsIk5qIiwiT2MiLCJQYyIsIlBlIiwK
            ICAgICAgICAiUWMiLCJRZSIsIlJjIiwiUmUiLCJSaSIsIlNjIiwiVGMiLCJVYyIsIlZjIiwiV2MiLCJXZyIsIlhjIiwiWGci
            LCJZYyIsIllkIiwKICAgICAgICAiYWQiLCJhZSIsImJkIiwiYmYiLCJjZCIsImRkIiwiZWQiLCJlZiIsImVrIiwiZmQiLCJm
            ZyIsImZoIiwiZmsiLCJnZCIsImhkIiwKICAgICAgICAiaWciLCJpaiIsImpkIiwia2QiLCJrZSIsImxkIiwibWQiLCJtaSIs
            Im5kIiwib2QiLCJvaCIsInBkIiwicGYiLCJxZCIsInJkIiwKICAgICAgICAic2QiLCJ0ZCIsInVkIiwidmQiLCJ3ZCIsIndn
            IiwieGQiLCJ4aCIsInlkIiwiemQiLAogICAgICAgICIkZCIsIiRlIiwiJGsiLCJBZSIsIkFmIiwiQWoiLCJCZSIsIkNlIiwi
            RGUiLCJFZSIsIkVrIiwiRW8iLCJFcCIsIkZlIiwiRm8iLAogICAgICAgICJHZSIsIkdoIiwiSGsiLCJJZSIsIklwIiwiSmUi
            LCJLZSIsIktrIiwiS3EiLCJMZSIsIkxoIiwiTGsiLCJNZSIsIk1tIiwiTmUiLAogICAgICAgICJPZSIsIlBlIiwiUWUiLCJS
            ZSIsIlJwIiwiU2UiLCJUZSIsIlVlIiwiVmUiLCJWcCIsIldlIiwiWGQiLCJYZSIsIllkIiwiWWUiLAogICAgICAgICJaZCIs
            IlplIiwiWmYiLCJaayIsImFlIiwiYWYiLCJhbCIsImJlIiwiYmYiLCJiZyIsImNlIiwiY3AiLCJkZiIsImRpIiwiZWUiLAog
            ICAgICAgICJlZiIsImZlIiwiZmYiLCJnZiIsImdtIiwiaGUiLCJoZiIsImllIiwiamUiLCJqZiIsImtlIiwia2YiLCJrbCIs
            ImxlIiwibGYiLAogICAgICAgICJsayIsIm1mIiwibWciLCJtbiIsIm5mIiwib2UiLCJvZiIsInBlIiwicGYiLCJwZyIsInFl
            IiwicWYiLCJyZSIsInJmIiwic2UiLAogICAgICAgICJzZiIsInRlIiwidGYiLCJ0aSIsInVlIiwidWYiLCJ2ZSIsInZmIiwi
            d2UiLCJ3ZiIsIndnIiwid2kiLCJ4ZSIsInllIiwieWYiLAogICAgICAgICJ5ayIsInlsIiwiemUiLCJ6ZiIsInprIgogICAg
            XTsKICAgIGZvciAoIGxldCBpID0gMDsgaSA8IHByb3BzLmxlbmd0aDsgaSsrICkgewogICAgICAgIGxbcHJvcHNbaV1dID0g
            bm9vcGZuOwogICAgfQogICAgd2luZG93LkwgPSB3aW5kb3cuSiA9IGw7Cn0pKCk7Cg==
            """
        ),
        RedirectResource(
            name: "nitropay_ads.js",
            mimeType: "text/javascript",
            base64: """
            LyoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
            KioqKioqKioKCiAgICB1QmxvY2sgT3JpZ2luIC0gYSBicm93c2VyIGV4dGVuc2lvbiB0byBibG9jayByZXF1ZXN0cy4KICAg
            IENvcHlyaWdodCAoQykgMjAxOS1wcmVzZW50IFJheW1vbmQgSGlsbAoKICAgIFRoaXMgcHJvZ3JhbSBpcyBmcmVlIHNvZnR3
            YXJlOiB5b3UgY2FuIHJlZGlzdHJpYnV0ZSBpdCBhbmQvb3IgbW9kaWZ5CiAgICBpdCB1bmRlciB0aGUgdGVybXMgb2YgdGhl
            IEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGFzIHB1Ymxpc2hlZCBieQogICAgdGhlIEZyZWUgU29mdHdhcmUgRm91bmRh
            dGlvbiwgZWl0aGVyIHZlcnNpb24gMyBvZiB0aGUgTGljZW5zZSwgb3IKICAgIChhdCB5b3VyIG9wdGlvbikgYW55IGxhdGVy
            IHZlcnNpb24uCgogICAgVGhpcyBwcm9ncmFtIGlzIGRpc3RyaWJ1dGVkIGluIHRoZSBob3BlIHRoYXQgaXQgd2lsbCBiZSB1
            c2VmdWwsCiAgICBidXQgV0lUSE9VVCBBTlkgV0FSUkFOVFk7IHdpdGhvdXQgZXZlbiB0aGUgaW1wbGllZCB3YXJyYW50eSBv
            ZgogICAgTUVSQ0hBTlRBQklMSVRZIG9yIEZJVE5FU1MgRk9SIEEgUEFSVElDVUxBUiBQVVJQT1NFLiAgU2VlIHRoZQogICAg
            R05VIEdlbmVyYWwgUHVibGljIExpY2Vuc2UgZm9yIG1vcmUgZGV0YWlscy4KCiAgICBZb3Ugc2hvdWxkIGhhdmUgcmVjZWl2
            ZWQgYSBjb3B5IG9mIHRoZSBHTlUgR2VuZXJhbCBQdWJsaWMgTGljZW5zZQogICAgYWxvbmcgd2l0aCB0aGlzIHByb2dyYW0u
            ICBJZiBub3QsIHNlZSB7aHR0cDovL3d3dy5nbnUub3JnL2xpY2Vuc2VzL30uCgogICAgSG9tZTogaHR0cHM6Ly9naXRodWIu
            Y29tL2dvcmhpbGwvdUJsb2NrCiovCgooZnVuY3Rpb24oKSB7CiAgICBpZiAoIHdpbmRvdy5uaXRyb0FkcyApIHsgcmV0dXJu
            OyB9CiAgICBjb25zdCBub29wZm4gPSBmdW5jdGlvbigpIHsKICAgICAgICA7CiAgICB9LmJpbmQoKTsKICAgIGNvbnN0IG5p
            dHJvQWRzID0gewogICAgICAgIGNyZWF0ZUFkOiBub29wZm4sCiAgICAgICAgcXVldWU6IFtdLAogICAgfTsKICAgIHdpbmRv
            dy5uaXRyb0FkcyA9IG5pdHJvQWRzOwp9KSgpOwo=
            """
        ),
        RedirectResource(
            name: "nobab2.js",
            mimeType: "text/javascript",
            base64: """
            LyoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
            KioqKioqKioKCiAgICB1QmxvY2sgT3JpZ2luIC0gYSBicm93c2VyIGV4dGVuc2lvbiB0byBibG9jayByZXF1ZXN0cy4KICAg
            IENvcHlyaWdodCAoQykgMjAyMS1wcmVzZW50IFJheW1vbmQgSGlsbAoKICAgIFRoaXMgcHJvZ3JhbSBpcyBmcmVlIHNvZnR3
            YXJlOiB5b3UgY2FuIHJlZGlzdHJpYnV0ZSBpdCBhbmQvb3IgbW9kaWZ5CiAgICBpdCB1bmRlciB0aGUgdGVybXMgb2YgdGhl
            IEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGFzIHB1Ymxpc2hlZCBieQogICAgdGhlIEZyZWUgU29mdHdhcmUgRm91bmRh
            dGlvbiwgZWl0aGVyIHZlcnNpb24gMyBvZiB0aGUgTGljZW5zZSwgb3IKICAgIChhdCB5b3VyIG9wdGlvbikgYW55IGxhdGVy
            IHZlcnNpb24uCgogICAgVGhpcyBwcm9ncmFtIGlzIGRpc3RyaWJ1dGVkIGluIHRoZSBob3BlIHRoYXQgaXQgd2lsbCBiZSB1
            c2VmdWwsCiAgICBidXQgV0lUSE9VVCBBTlkgV0FSUkFOVFk7IHdpdGhvdXQgZXZlbiB0aGUgaW1wbGllZCB3YXJyYW50eSBv
            ZgogICAgTUVSQ0hBTlRBQklMSVRZIG9yIEZJVE5FU1MgRk9SIEEgUEFSVElDVUxBUiBQVVJQT1NFLiAgU2VlIHRoZQogICAg
            R05VIEdlbmVyYWwgUHVibGljIExpY2Vuc2UgZm9yIG1vcmUgZGV0YWlscy4KCiAgICBZb3Ugc2hvdWxkIGhhdmUgcmVjZWl2
            ZWQgYSBjb3B5IG9mIHRoZSBHTlUgR2VuZXJhbCBQdWJsaWMgTGljZW5zZQogICAgYWxvbmcgd2l0aCB0aGlzIHByb2dyYW0u
            ICBJZiBub3QsIHNlZSB7aHR0cDovL3d3dy5nbnUub3JnL2xpY2Vuc2VzL30uCgogICAgSG9tZTogaHR0cHM6Ly9naXRodWIu
            Y29tL2dvcmhpbGwvdUJsb2NrCiovCgooZnVuY3Rpb24oKSB7CiAgICAndXNlIHN0cmljdCc7CiAgICBjb25zdCBzY3JpcHQg
            PSBkb2N1bWVudC5jdXJyZW50U2NyaXB0OwogICAgaWYgKCBzY3JpcHQgPT09IG51bGwgKSB7IHJldHVybjsgfQogICAgY29u
            c3Qgc3JjID0gc2NyaXB0LnNyYzsKICAgIGlmICggdHlwZW9mIHNyYyAhPT0gJ3N0cmluZycgKSB7IHJldHVybjsgfQogICAg
            Ly8gVGhlIHNjcmlwbGV0IGlzIG1lYW50IHRvIGFjdCBPTkxZIHdoZW4gaXQncyBiZWluZyB1c2VkIGFzIGEgcmVkaXJlY3Rp
            b24KICAgIC8vIGZvciBzcGVjaWZpYyBkb21haW5zLgogICAgY29uc3QgcmUgPSBuZXcgUmVnRXhwKAogICAgICAgICdeaHR0
            cHM/Oi8vW1xcdy1dK1xcLignICsKICAgICAgICBbCiAgICAgICAgICAgICdhZGNsaXh4XFwubmV0JywKICAgICAgICAgICAg
            J2FkbmV0YXNpYVxcLmNvbScsCiAgICAgICAgICAgICdhZHRyYWNrZXJzXFwubmV0JywKICAgICAgICAgICAgJ2Jhbm5lcnRy
            YWNrXFwubmV0JywKICAgICAgICBdLmpvaW4oJ3wnKSArCiAgICAgICAgJykvLicKICAgICk7CiAgICBpZiAoIHJlLnRlc3Qo
            c3JjKSA9PT0gZmFsc2UgKSB7IHJldHVybjsgfQogICAgd2luZG93Lm5IN2VYek9zRyA9IDg1ODsKfSkoKTsK
            """
        ),
        RedirectResource(
            name: "noeval-silent.js",
            mimeType: "text/javascript",
            base64: """
            LyoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
            KioqKioqKioKCiAgICB1QmxvY2sgT3JpZ2luIC0gYSBicm93c2VyIGV4dGVuc2lvbiB0byBibG9jayByZXF1ZXN0cy4KICAg
            IENvcHlyaWdodCAoQykgMjAxOS1wcmVzZW50IFJheW1vbmQgSGlsbAoKICAgIFRoaXMgcHJvZ3JhbSBpcyBmcmVlIHNvZnR3
            YXJlOiB5b3UgY2FuIHJlZGlzdHJpYnV0ZSBpdCBhbmQvb3IgbW9kaWZ5CiAgICBpdCB1bmRlciB0aGUgdGVybXMgb2YgdGhl
            IEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGFzIHB1Ymxpc2hlZCBieQogICAgdGhlIEZyZWUgU29mdHdhcmUgRm91bmRh
            dGlvbiwgZWl0aGVyIHZlcnNpb24gMyBvZiB0aGUgTGljZW5zZSwgb3IKICAgIChhdCB5b3VyIG9wdGlvbikgYW55IGxhdGVy
            IHZlcnNpb24uCgogICAgVGhpcyBwcm9ncmFtIGlzIGRpc3RyaWJ1dGVkIGluIHRoZSBob3BlIHRoYXQgaXQgd2lsbCBiZSB1
            c2VmdWwsCiAgICBidXQgV0lUSE9VVCBBTlkgV0FSUkFOVFk7IHdpdGhvdXQgZXZlbiB0aGUgaW1wbGllZCB3YXJyYW50eSBv
            ZgogICAgTUVSQ0hBTlRBQklMSVRZIG9yIEZJVE5FU1MgRk9SIEEgUEFSVElDVUxBUiBQVVJQT1NFLiAgU2VlIHRoZQogICAg
            R05VIEdlbmVyYWwgUHVibGljIExpY2Vuc2UgZm9yIG1vcmUgZGV0YWlscy4KCiAgICBZb3Ugc2hvdWxkIGhhdmUgcmVjZWl2
            ZWQgYSBjb3B5IG9mIHRoZSBHTlUgR2VuZXJhbCBQdWJsaWMgTGljZW5zZQogICAgYWxvbmcgd2l0aCB0aGlzIHByb2dyYW0u
            ICBJZiBub3QsIHNlZSB7aHR0cDovL3d3dy5nbnUub3JnL2xpY2Vuc2VzL30uCgogICAgSG9tZTogaHR0cHM6Ly9naXRodWIu
            Y29tL2dvcmhpbGwvdUJsb2NrCiovCgooZnVuY3Rpb24oKSB7CiAgICAndXNlIHN0cmljdCc7CiAgICB3aW5kb3cuZXZhbCA9
            IG5ldyBQcm94eSh3aW5kb3cuZXZhbCwgeyAgICAgICAgICAvLyBqc2hpbnQgaWdub3JlOiBsaW5lCiAgICAgICAgYXBwbHk6
            IGZ1bmN0aW9uKCkgewogICAgICAgIH0KICAgIH0pOwp9KSgpOwo=
            """
        ),
        RedirectResource(
            name: "noeval.js",
            mimeType: "text/javascript",
            base64: """
            LyoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
            KioqKioqKioKCiAgICB1QmxvY2sgT3JpZ2luIC0gYSBicm93c2VyIGV4dGVuc2lvbiB0byBibG9jayByZXF1ZXN0cy4KICAg
            IENvcHlyaWdodCAoQykgMjAxOS1wcmVzZW50IFJheW1vbmQgSGlsbAoKICAgIFRoaXMgcHJvZ3JhbSBpcyBmcmVlIHNvZnR3
            YXJlOiB5b3UgY2FuIHJlZGlzdHJpYnV0ZSBpdCBhbmQvb3IgbW9kaWZ5CiAgICBpdCB1bmRlciB0aGUgdGVybXMgb2YgdGhl
            IEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGFzIHB1Ymxpc2hlZCBieQogICAgdGhlIEZyZWUgU29mdHdhcmUgRm91bmRh
            dGlvbiwgZWl0aGVyIHZlcnNpb24gMyBvZiB0aGUgTGljZW5zZSwgb3IKICAgIChhdCB5b3VyIG9wdGlvbikgYW55IGxhdGVy
            IHZlcnNpb24uCgogICAgVGhpcyBwcm9ncmFtIGlzIGRpc3RyaWJ1dGVkIGluIHRoZSBob3BlIHRoYXQgaXQgd2lsbCBiZSB1
            c2VmdWwsCiAgICBidXQgV0lUSE9VVCBBTlkgV0FSUkFOVFk7IHdpdGhvdXQgZXZlbiB0aGUgaW1wbGllZCB3YXJyYW50eSBv
            ZgogICAgTUVSQ0hBTlRBQklMSVRZIG9yIEZJVE5FU1MgRk9SIEEgUEFSVElDVUxBUiBQVVJQT1NFLiAgU2VlIHRoZQogICAg
            R05VIEdlbmVyYWwgUHVibGljIExpY2Vuc2UgZm9yIG1vcmUgZGV0YWlscy4KCiAgICBZb3Ugc2hvdWxkIGhhdmUgcmVjZWl2
            ZWQgYSBjb3B5IG9mIHRoZSBHTlUgR2VuZXJhbCBQdWJsaWMgTGljZW5zZQogICAgYWxvbmcgd2l0aCB0aGlzIHByb2dyYW0u
            ICBJZiBub3QsIHNlZSB7aHR0cDovL3d3dy5nbnUub3JnL2xpY2Vuc2VzL30uCgogICAgSG9tZTogaHR0cHM6Ly9naXRodWIu
            Y29tL2dvcmhpbGwvdUJsb2NrCiovCgooZnVuY3Rpb24oKSB7CiAgICAndXNlIHN0cmljdCc7CiAgICBjb25zdCBsb2cgPSBj
            b25zb2xlLmxvZy5iaW5kKGNvbnNvbGUpOwogICAgd2luZG93LmV2YWwgPSBuZXcgUHJveHkod2luZG93LmV2YWwsIHsgICAg
            ICAgICAgLy8ganNoaW50IGlnbm9yZTogbGluZQogICAgICAgIGFwcGx5OiBmdW5jdGlvbih0YXJnZXQsIHRoaXNBcmcsIGFy
            Z3MpIHsKICAgICAgICAgICAgbG9nKGBEb2N1bWVudCB0cmllZCB0byBldmFsLi4uICR7YXJnc1swXX1cbmApOwogICAgICAg
            IH0KICAgIH0pOwp9KSgpOwo=
            """
        ),
        RedirectResource(
            name: "nofab.js",
            mimeType: "text/javascript",
            base64: """
            LyoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
            KioqKioqKioKCiAgICB1QmxvY2sgT3JpZ2luIC0gYSBicm93c2VyIGV4dGVuc2lvbiB0byBibG9jayByZXF1ZXN0cy4KICAg
            IENvcHlyaWdodCAoQykgMjAxOS1wcmVzZW50IFJheW1vbmQgSGlsbAoKICAgIFRoaXMgcHJvZ3JhbSBpcyBmcmVlIHNvZnR3
            YXJlOiB5b3UgY2FuIHJlZGlzdHJpYnV0ZSBpdCBhbmQvb3IgbW9kaWZ5CiAgICBpdCB1bmRlciB0aGUgdGVybXMgb2YgdGhl
            IEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGFzIHB1Ymxpc2hlZCBieQogICAgdGhlIEZyZWUgU29mdHdhcmUgRm91bmRh
            dGlvbiwgZWl0aGVyIHZlcnNpb24gMyBvZiB0aGUgTGljZW5zZSwgb3IKICAgIChhdCB5b3VyIG9wdGlvbikgYW55IGxhdGVy
            IHZlcnNpb24uCgogICAgVGhpcyBwcm9ncmFtIGlzIGRpc3RyaWJ1dGVkIGluIHRoZSBob3BlIHRoYXQgaXQgd2lsbCBiZSB1
            c2VmdWwsCiAgICBidXQgV0lUSE9VVCBBTlkgV0FSUkFOVFk7IHdpdGhvdXQgZXZlbiB0aGUgaW1wbGllZCB3YXJyYW50eSBv
            ZgogICAgTUVSQ0hBTlRBQklMSVRZIG9yIEZJVE5FU1MgRk9SIEEgUEFSVElDVUxBUiBQVVJQT1NFLiAgU2VlIHRoZQogICAg
            R05VIEdlbmVyYWwgUHVibGljIExpY2Vuc2UgZm9yIG1vcmUgZGV0YWlscy4KCiAgICBZb3Ugc2hvdWxkIGhhdmUgcmVjZWl2
            ZWQgYSBjb3B5IG9mIHRoZSBHTlUgR2VuZXJhbCBQdWJsaWMgTGljZW5zZQogICAgYWxvbmcgd2l0aCB0aGlzIHByb2dyYW0u
            ICBJZiBub3QsIHNlZSB7aHR0cDovL3d3dy5nbnUub3JnL2xpY2Vuc2VzL30uCgogICAgSG9tZTogaHR0cHM6Ly9naXRodWIu
            Y29tL2dvcmhpbGwvdUJsb2NrCiovCgooZnVuY3Rpb24oKSB7CiAgICAndXNlIHN0cmljdCc7CiAgICBjb25zdCBub29wZm4g
            PSBmdW5jdGlvbigpIHsKICAgIH07CiAgICBjb25zdCBGYWIgPSBmdW5jdGlvbigpIHt9OwogICAgRmFiLnByb3RvdHlwZS5j
            aGVjayA9IG5vb3BmbjsKICAgIEZhYi5wcm90b3R5cGUuY2xlYXJFdmVudCA9IG5vb3BmbjsKICAgIEZhYi5wcm90b3R5cGUu
            ZW1pdEV2ZW50ID0gbm9vcGZuOwogICAgRmFiLnByb3RvdHlwZS5vbiA9IGZ1bmN0aW9uKGEsIGIpIHsKICAgICAgICBpZiAo
            ICFhICkgeyBiKCk7IH0KICAgICAgICByZXR1cm4gdGhpczsKICAgIH07CiAgICBGYWIucHJvdG90eXBlLm9uRGV0ZWN0ZWQg
            PSBmdW5jdGlvbigpIHsKICAgICAgICByZXR1cm4gdGhpczsKICAgIH07CiAgICBGYWIucHJvdG90eXBlLm9uTm90RGV0ZWN0
            ZWQgPSBmdW5jdGlvbihhKSB7CiAgICAgICAgYSgpOwogICAgICAgIHJldHVybiB0aGlzOwogICAgfTsKICAgIEZhYi5wcm90
            b3R5cGUuc2V0T3B0aW9uID0gbm9vcGZuOwogICAgRmFiLnByb3RvdHlwZS5vcHRpb25zID0gewogICAgICAgIHNldDogbm9v
            cGZuLAogICAgICAgIGdldDogbm9vcGZuLAogICAgfTsKICAgIGNvbnN0IGZhYiA9IG5ldyBGYWIoKTsKICAgIGNvbnN0IGdl
            dFNldEZhYiA9IHsKICAgICAgICBnZXQ6IGZ1bmN0aW9uKCkgeyByZXR1cm4gRmFiOyB9LAogICAgICAgIHNldDogZnVuY3Rp
            b24oKSB7fQogICAgfTsKICAgIGNvbnN0IGdldHNldGZhYiA9IHsKICAgICAgICBnZXQ6IGZ1bmN0aW9uKCkgeyByZXR1cm4g
            ZmFiOyB9LAogICAgICAgIHNldDogZnVuY3Rpb24oKSB7fQogICAgfTsKICAgIGlmICggd2luZG93Lmhhc093blByb3BlcnR5
            KCdGdWNrQWRCbG9jaycpICkgeyB3aW5kb3cuRnVja0FkQmxvY2sgPSBGYWI7IH0KICAgIGVsc2UgeyBPYmplY3QuZGVmaW5l
            UHJvcGVydHkod2luZG93LCAnRnVja0FkQmxvY2snLCBnZXRTZXRGYWIpOyB9CiAgICBpZiAoIHdpbmRvdy5oYXNPd25Qcm9w
            ZXJ0eSgnQmxvY2tBZEJsb2NrJykgKSB7IHdpbmRvdy5CbG9ja0FkQmxvY2sgPSBGYWI7IH0KICAgIGVsc2UgeyBPYmplY3Qu
            ZGVmaW5lUHJvcGVydHkod2luZG93LCAnQmxvY2tBZEJsb2NrJywgZ2V0U2V0RmFiKTsgfQogICAgaWYgKCB3aW5kb3cuaGFz
            T3duUHJvcGVydHkoJ1NuaWZmQWRCbG9jaycpICkgeyB3aW5kb3cuU25pZmZBZEJsb2NrID0gRmFiOyB9CiAgICBlbHNlIHsg
            T2JqZWN0LmRlZmluZVByb3BlcnR5KHdpbmRvdywgJ1NuaWZmQWRCbG9jaycsIGdldFNldEZhYik7IH0KICAgIGlmICggd2lu
            ZG93Lmhhc093blByb3BlcnR5KCdmdWNrQWRCbG9jaycpICkgeyB3aW5kb3cuZnVja0FkQmxvY2sgPSBmYWI7IH0KICAgIGVs
            c2UgeyBPYmplY3QuZGVmaW5lUHJvcGVydHkod2luZG93LCAnZnVja0FkQmxvY2snLCBnZXRzZXRmYWIpOyB9CiAgICBpZiAo
            IHdpbmRvdy5oYXNPd25Qcm9wZXJ0eSgnYmxvY2tBZEJsb2NrJykgKSB7IHdpbmRvdy5ibG9ja0FkQmxvY2sgPSBmYWI7IH0K
            ICAgIGVsc2UgeyBPYmplY3QuZGVmaW5lUHJvcGVydHkod2luZG93LCAnYmxvY2tBZEJsb2NrJywgZ2V0c2V0ZmFiKTsgfQog
            ICAgaWYgKCB3aW5kb3cuaGFzT3duUHJvcGVydHkoJ3NuaWZmQWRCbG9jaycpICkgeyB3aW5kb3cuc25pZmZBZEJsb2NrID0g
            ZmFiOyB9CiAgICBlbHNlIHsgT2JqZWN0LmRlZmluZVByb3BlcnR5KHdpbmRvdywgJ3NuaWZmQWRCbG9jaycsIGdldHNldGZh
            Yik7IH0KfSkoKTsK
            """
        ),
        RedirectResource(
            name: "noop-0.1s.mp3",
            mimeType: "audio/mp3",
            base64: """
            SUQzBAAAAAAAI1RTU0UAAAAPAAADTGF2ZjU2LjQwLjEwMQAAAAAAAAAAAAAA//tUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
            AAAAAAAAAAAASW5mbwAAAA8AAAAGAAADAABgYGBgYGBgYGBgYGBgYGBggICAgICAgICAgICAgICAgICgoKCgoKCgoKCgoKCg
            oKCgwMDAwMDAwMDAwMDAwMDAwMDg4ODg4ODg4ODg4ODg4ODg4P////////////////////8AAAAATGF2YzU2LjYwAAAAAAAA
            AAAAAAAAJAAAAAAAAAAAAwDNZKlY//sUZAAP8AAAaQAAAAgAAA0gAAABAAABpAAAACAAADSAAAAETEFNRTMuOTkuNVVVVVVV
            VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sUZB4P8AAAaQAAAAgAAA0gAAABAAABpAAA
            ACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sU
            ZDwP8AAAaQAAAAgAAA0gAAABAAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV
            VVVVVVVVVVVVVVVVVVVVVVVVVVVV//sUZFoP8AAAaQAAAAgAAA0gAAABAAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVV
            VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sUZHgP8AAAaQAAAAgAAA0gAAABAAABpAAA
            ACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sU
            ZJYP8AAAaQAAAAgAAA0gAAABAAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV
            VVVVVVVVVVVVVVVVVVVVVVVVVVVV
            """
        ),
        RedirectResource(
            name: "noop-0.5s.mp3",
            mimeType: "audio/mp3",
            base64: """
            SUQzBAAAAAAAI1RTU0UAAAAPAAADTGF2ZjU4LjI5LjEwMAAAAAAAAAAAAAAA//tUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
            AAAAAAAAAAAASW5mbwAAAA8AAAAWAAAJAAAgICAgKioqKio1NTU1QEBAQEBKSkpKVVVVVVVgYGBgampqamp1dXV1gICAgICK
            ioqKlZWVlZWgoKCgoKqqqqq1tbW1tcDAwMDKysrKytXV1dXg4ODg4Orq6ur19fX19f////8AAAAATGF2YzU4LjU0AAAAAAAA
            AAAAAAAAJAMAAAAAAAAACQDI0dkC//sUZAAP8AAAaQAAAAgAAA0gAAABAAABpAAAACAAADSAAAAETEFNRTMuMTAwVVVVVVVV
            VVVVVVVVVVVVVVVVVVVMQU1FMy4xMDBVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sUZB4P8AAAaQAAAAgAAA0gAAABAAABpAAA
            ACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVMQU1FMy4xMDBVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sU
            ZDwP8AAAaQAAAAgAAA0gAAABAAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVMQU1FMy4xMDBV
            VVVVVVVVVVVVVVVVVVVVVVVVVVVV//sUZFoP8AAAaQAAAAgAAA0gAAABAAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVV
            VVVVVVVVVVVVVVVVVVVMQU1FMy4xMDBVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sUZHgP8AAAaQAAAAgAAA0gAAABAAABpAAA
            ACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVMQU1FMy4xMDBVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sU
            ZJYP8AAAaQAAAAgAAA0gAAABAAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVMQU1FMy4xMDBV
            VVVVVVVVVVVVVVVVVVVVVVVVVVVV//sUZLQP8AAAaQAAAAgAAA0gAAABAAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVV
            VVVVVVVVVVVVVVVVVVVMQU1FMy4xMDBVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sUZNIP8AAAaQAAAAgAAA0gAAABAAABpAAA
            ACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVMQU1FMy4xMDBVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sU
            ZOGP8AAAaQAAAAgAAA0gAAABAAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVMQU1FMy4xMDBV
            VVVVVVVVVVVVVVVVVVVVVVVVVVVV//sUZOGP8AAAaQAAAAgAAA0gAAABAAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVV
            VVVVVVVVVVVVVVVVVVVMQU1FMy4xMDBVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sUZOGP8AAAaQAAAAgAAA0gAAABAAABpAAA
            ACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVMQU1FMy4xMDBVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sU
            ZOGP8AAAaQAAAAgAAA0gAAABAAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVMQU1FMy4xMDBV
            VVVVVVVVVVVVVVVVVVVVVVVVVVVV//sUZOGP8AAAaQAAAAgAAA0gAAABAAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVV
            VVVVVVVVVVVVVVVVVVVMQU1FMy4xMDBVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sUZOGP8AAAaQAAAAgAAA0gAAABAAABpAAA
            ACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVMQU1FMy4xMDBVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sU
            ZOGP8AAAaQAAAAgAAA0gAAABAAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV
            VVVVVVVVVVVVVVVVVVVVVVVVVVVV//sUZOGP8AAAaQAAAAgAAA0gAAABAAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVV
            VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sUZOGP8AAAaQAAAAgAAA0gAAABAAABpAAA
            ACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sU
            ZOGP8AAAaQAAAAgAAA0gAAABAAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV
            VVVVVVVVVVVVVVVVVVVVVVVVVVVV//sUZOGP8AAAaQAAAAgAAA0gAAABAAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVV
            VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sUZOGP8AAAaQAAAAgAAA0gAAABAAABpAAA
            ACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sU
            ZOGP8AAAaQAAAAgAAA0gAAABAAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV
            VVVVVVVVVVVVVVVVVVVVVVVVVVVV//sUZOGP8AAAaQAAAAgAAA0gAAABAAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVV
            VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV
            """
        ),
        RedirectResource(
            name: "noop-1s.mp4",
            mimeType: "video/mp4",
            base64: """
            AAAAHGZ0eXBNNFYgAAACAGlzb21pc28yYXZjMQAAAAhmcmVlAAAGF21kYXTeBAAAbGliZmFhYyAxLjI4AABCAJMgBDIARwAA
            ArEGBf//rdxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNDIgcjIgOTU2YzhkOCAtIEguMjY0L01QRUctNCBBVkMgY29k
            ZWMgLSBDb3B5bGVmdCAyMDAzLTIwMTQgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0Lmh0bWwgLSBvcHRpb25zOiBj
            YWJhYz0wIHJlZj0zIGRlYmxvY2s9MTowOjAgYW5hbHlzZT0weDE6MHgxMTEgbWU9aGV4IHN1Ym1lPTcgcHN5PTEgcHN5X3Jk
            PTEuMDA6MC4wMCBtaXhlZF9yZWY9MSBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTEgOHg4ZGN0PTAgY3FtPTAg
            ZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9LTIgdGhyZWFkcz02IGxvb2thaGVhZF90aHJl
            YWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25z
            dHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5aW50PTI1MCBrZXlpbnRfbWluPTI1IHNjZW5lY3V0PTQw
            IGludHJhX3JlZnJlc2g9MCByY19sb29rYWhlYWQ9NDAgcmM9Y3JmIG1idHJlZT0xIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBt
            aW49MCBxcG1heD02OSBxcHN0ZXA9NCB2YnZfbWF4cmF0ZT03NjggdmJ2X2J1ZnNpemU9MzAwMCBjcmZfbWF4PTAuMCBuYWxf
            aHJkPW5vbmUgZmlsbGVyPTAgaXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAAAFZliIQL8mKAAKvMnJycnJycnJycnXXXXXXX
            XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXiEASZACGQAjgCEA
            SZACGQAjgAAAAAdBmjgX4GSAIQBJkAIZACOAAAAAB0GaVAX4GSAhAEmQAhkAI4AhAEmQAhkAI4AAAAAGQZpgL8DJIQBJkAIZ
            ACOAIQBJkAIZACOAAAAABkGagC/AySEASZACGQAjgAAAAAZBmqAvwMkhAEmQAhkAI4AhAEmQAhkAI4AAAAAGQZrAL8DJIQBJ
            kAIZACOAAAAABkGa4C/AySEASZACGQAjgCEASZACGQAjgAAAAAZBmwAvwMkhAEmQAhkAI4AAAAAGQZsgL8DJIQBJkAIZACOA
            IQBJkAIZACOAAAAABkGbQC/AySEASZACGQAjgCEASZACGQAjgAAAAAZBm2AvwMkhAEmQAhkAI4AAAAAGQZuAL8DJIQBJkAIZ
            ACOAIQBJkAIZACOAAAAABkGboC/AySEASZACGQAjgAAAAAZBm8AvwMkhAEmQAhkAI4AhAEmQAhkAI4AAAAAGQZvgL8DJIQBJ
            kAIZACOAAAAABkGaAC/AySEASZACGQAjgCEASZACGQAjgAAAAAZBmiAvwMkhAEmQAhkAI4AhAEmQAhkAI4AAAAAGQZpAL8DJ
            IQBJkAIZACOAAAAABkGaYC/AySEASZACGQAjgCEASZACGQAjgAAAAAZBmoAvwMkhAEmQAhkAI4AAAAAGQZqgL8DJIQBJkAIZ
            ACOAIQBJkAIZACOAAAAABkGawC/AySEASZACGQAjgAAAAAZBmuAvwMkhAEmQAhkAI4AhAEmQAhkAI4AAAAAGQZsAL8DJIQBJ
            kAIZACOAAAAABkGbIC/AySEASZACGQAjgCEASZACGQAjgAAAAAZBm0AvwMkhAEmQAhkAI4AhAEmQAhkAI4AAAAAGQZtgL8DJ
            IQBJkAIZACOAAAAABkGbgCvAySEASZACGQAjgCEASZACGQAjgAAAAAZBm6AnwMkhAEmQAhkAI4AhAEmQAhkAI4AhAEmQAhkA
            I4AhAEmQAhkAI4AAAAhubW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAABDcAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAA
            AAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAwAAAzB0cmFrAAAAXHRraGQA
            AAADAAAAAAAAAAAAAAABAAAAAAAAA+kAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABA
            AAAAALAAAACQAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAPpAAAAAAABAAAAAAKobWRpYQAAACBtZGhkAAAAAAAAAAAA
            AAAAAAB1MAAAdU5VxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAACU21pbmYAAAAU
            dm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAhNzdGJsAAAAr3N0c2QAAAAA
            AAAAAQAAAJ9hdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAALAAkABIAAAASAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAA
            AAAAAAAAAAAAAAAAAAAAGP//AAAALWF2Y0MBQsAN/+EAFWdCwA3ZAsTsBEAAAPpAADqYA8UKkgEABWjLg8sgAAAAHHV1aWRr
            aEDyXyRPxbo5pRvPAyPzAAAAAAAAABhzdHRzAAAAAAAAAAEAAAAeAAAD6QAAABRzdHNzAAAAAAAAAAEAAAABAAAAHHN0c2MA
            AAAAAAAAAQAAAAEAAAABAAAAAQAAAIxzdHN6AAAAAAAAAAAAAAAeAAADDwAAAAsAAAALAAAACgAAAAoAAAAKAAAACgAAAAoA
            AAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoA
            AAAKAAAACgAAAAoAAAAKAAAAiHN0Y28AAAAAAAAAHgAAAEYAAANnAAADewAAA5gAAAO0AAADxwAAA+MAAAP2AAAEEgAABCUA
            AARBAAAEXQAABHAAAASMAAAEnwAABLsAAATOAAAE6gAABQYAAAUZAAAFNQAABUgAAAVkAAAFdwAABZMAAAWmAAAFwgAABd4A
            AAXxAAAGDQAABGh0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAACAAAAAAAABDcAAAAAAAAAAAAAAAEBAAAAAAEAAAAAAAAA
            AAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAQkAAADcAABAAAA
            AAPgbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAC7gAAAykBVxAAAAAAALWhkbHIAAAAAAAAAAHNvdW4AAAAAAAAAAAAAAABT
            b3VuZEhhbmRsZXIAAAADi21pbmYAAAAQc21oZAAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAAB
            AAADT3N0YmwAAABnc3RzZAAAAAAAAAABAAAAV21wNGEAAAAAAAAAAQAAAAAAAAAAAAIAEAAAAAC7gAAAAAAAM2VzZHMAAAAA
            A4CAgCIAAgAEgICAFEAVBbjYAAu4AAAADcoFgICAAhGQBoCAgAECAAAAIHN0dHMAAAAAAAAAAgAAADIAAAQAAAAAAQAAAkAA
            AAFUc3RzYwAAAAAAAAAbAAAAAQAAAAEAAAABAAAAAgAAAAIAAAABAAAAAwAAAAEAAAABAAAABAAAAAIAAAABAAAABgAAAAEA
            AAABAAAABwAAAAIAAAABAAAACAAAAAEAAAABAAAACQAAAAIAAAABAAAACgAAAAEAAAABAAAACwAAAAIAAAABAAAADQAAAAEA
            AAABAAAADgAAAAIAAAABAAAADwAAAAEAAAABAAAAEAAAAAIAAAABAAAAEQAAAAEAAAABAAAAEgAAAAIAAAABAAAAFAAAAAEA
            AAABAAAAFQAAAAIAAAABAAAAFgAAAAEAAAABAAAAFwAAAAIAAAABAAAAGAAAAAEAAAABAAAAGQAAAAIAAAABAAAAGgAAAAEA
            AAABAAAAGwAAAAIAAAABAAAAHQAAAAEAAAABAAAAHgAAAAIAAAABAAAAHwAAAAQAAAABAAAA4HN0c3oAAAAAAAAAAAAAADMA
            AAAaAAAACQAAAAkAAAAJAAAACQAAAAkAAAAJAAAACQAAAAkAAAAJAAAACQAAAAkAAAAJAAAACQAAAAkAAAAJAAAACQAAAAkA
            AAAJAAAACQAAAAkAAAAJAAAACQAAAAkAAAAJAAAACQAAAAkAAAAJAAAACQAAAAkAAAAJAAAACQAAAAkAAAAJAAAACQAAAAkA
            AAAJAAAACQAAAAkAAAAJAAAACQAAAAkAAAAJAAAACQAAAAkAAAAJAAAACQAAAAkAAAAJAAAACQAAAAkAAACMc3RjbwAAAAAA
            AAAfAAAALAAAA1UAAANyAAADhgAAA6IAAAO+AAAD0QAAA+0AAAQAAAAEHAAABC8AAARLAAAEZwAABHoAAASWAAAEqQAABMUA
            AATYAAAE9AAABRAAAAUjAAAFPwAABVIAAAVuAAAFgQAABZ0AAAWwAAAFzAAABegAAAX7AAAGFwAAAGJ1ZHRhAAAAWm1ldGEA
            AAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALWlsc3QAAAAlqXRvbwAAAB1kYXRhAAAAAQAAAABMYXZm
            NTUuMzMuMTAw
            """
        ),
        RedirectResource(
            name: "noop-vast2.xml",
            mimeType: "text/xml",
            base64: """
            PFZBU1QgdmVyc2lvbj0iMi4wIj48L1ZBU1Q+Cg==
            """
        ),
        RedirectResource(
            name: "noop-vast3.xml",
            mimeType: "text/xml",
            base64: """
            PFZBU1QgdmVyc2lvbj0iMy4wIj48L1ZBU1Q+Cg==
            """
        ),
        RedirectResource(
            name: "noop-vast4.xml",
            mimeType: "text/xml",
            base64: """
            PFZBU1QgdmVyc2lvbj0iNC4wIj48L1ZBU1Q+Cg==
            """
        ),
        RedirectResource(
            name: "noop-vmap1.xml",
            mimeType: "text/xml",
            base64: """
            PHZtYXA6Vk1BUCB4bWxuczp2bWFwPSJodHRwOi8vd3d3LmlhYi5uZXQvdmlkZW9zdWl0ZS92bWFwIiB2ZXJzaW9uPSIxLjAi
            Pjwvdm1hcDpWTUFQPgo=
            """
        ),
        RedirectResource(
            name: "noop.css",
            mimeType: "text/css",
            base64: """
            LyogKi8K
            """
        ),
        RedirectResource(
            name: "noop.html",
            mimeType: "text/html",
            base64: """
            PCFET0NUWVBFIGh0bWw+CjxodG1sPgogICAgPGhlYWQ+PHRpdGxlPjwvdGl0bGU+PC9oZWFkPgogICAgPGJvZHk+PC9ib2R5
            Pgo8L2h0bWw+Cg==
            """
        ),
        RedirectResource(
            name: "noop.js",
            mimeType: "text/javascript",
            base64: """
            KGZ1bmN0aW9uKCkgewogICAgJ3VzZSBzdHJpY3QnOwp9KSgpOwo=
            """
        ),
        RedirectResource(
            name: "noop.json",
            mimeType: "application/json",
            base64: """
            e30=
            """
        ),
        RedirectResource(
            name: "noop.txt",
            mimeType: "text/plain",
            base64: """
            Cg==
            """
        ),
        RedirectResource(
            name: "outbrain-widget.js",
            mimeType: "text/javascript",
            base64: """
            LyoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
            KioqKioqKioKCiAgICB1QmxvY2sgT3JpZ2luIC0gYSBicm93c2VyIGV4dGVuc2lvbiB0byBibG9jayByZXF1ZXN0cy4KICAg
            IENvcHlyaWdodCAoQykgMjAxOS1wcmVzZW50IFJheW1vbmQgSGlsbAoKICAgIFRoaXMgcHJvZ3JhbSBpcyBmcmVlIHNvZnR3
            YXJlOiB5b3UgY2FuIHJlZGlzdHJpYnV0ZSBpdCBhbmQvb3IgbW9kaWZ5CiAgICBpdCB1bmRlciB0aGUgdGVybXMgb2YgdGhl
            IEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGFzIHB1Ymxpc2hlZCBieQogICAgdGhlIEZyZWUgU29mdHdhcmUgRm91bmRh
            dGlvbiwgZWl0aGVyIHZlcnNpb24gMyBvZiB0aGUgTGljZW5zZSwgb3IKICAgIChhdCB5b3VyIG9wdGlvbikgYW55IGxhdGVy
            IHZlcnNpb24uCgogICAgVGhpcyBwcm9ncmFtIGlzIGRpc3RyaWJ1dGVkIGluIHRoZSBob3BlIHRoYXQgaXQgd2lsbCBiZSB1
            c2VmdWwsCiAgICBidXQgV0lUSE9VVCBBTlkgV0FSUkFOVFk7IHdpdGhvdXQgZXZlbiB0aGUgaW1wbGllZCB3YXJyYW50eSBv
            ZgogICAgTUVSQ0hBTlRBQklMSVRZIG9yIEZJVE5FU1MgRk9SIEEgUEFSVElDVUxBUiBQVVJQT1NFLiAgU2VlIHRoZQogICAg
            R05VIEdlbmVyYWwgUHVibGljIExpY2Vuc2UgZm9yIG1vcmUgZGV0YWlscy4KCiAgICBZb3Ugc2hvdWxkIGhhdmUgcmVjZWl2
            ZWQgYSBjb3B5IG9mIHRoZSBHTlUgR2VuZXJhbCBQdWJsaWMgTGljZW5zZQogICAgYWxvbmcgd2l0aCB0aGlzIHByb2dyYW0u
            ICBJZiBub3QsIHNlZSB7aHR0cDovL3d3dy5nbnUub3JnL2xpY2Vuc2VzL30uCgogICAgSG9tZTogaHR0cHM6Ly9naXRodWIu
            Y29tL2dvcmhpbGwvdUJsb2NrCiovCgooZnVuY3Rpb24oKSB7CiAgICAndXNlIHN0cmljdCc7CiAgICBjb25zdCBub29wZm4g
            PSBmdW5jdGlvbigpIHsKICAgIH07CiAgICBjb25zdCBvYnIgPSB7fTsKICAgIGNvbnN0IG1ldGhvZHMgPSBbCiAgICAgICAg
            J2NhbGxDbGljaycsCiAgICAgICAgJ2NhbGxMb2FkTW9yZScsCiAgICAgICAgJ2NhbGxSZWNzJywKICAgICAgICAnY2FsbFVz
            ZXJaYXBwaW5nJywKICAgICAgICAnY2FsbFdoYXRJcycsCiAgICAgICAgJ2NhbmNlbFJlY29tbWVuZGF0aW9uJywKICAgICAg
            ICAnY2FuY2VsUmVjcycsCiAgICAgICAgJ2Nsb3NlQ2FyZCcsCiAgICAgICAgJ2Nsb3NlTW9kYWwnLAogICAgICAgICdjbG9z
            ZVRieCcsCiAgICAgICAgJ2Vycm9ySW5qZWN0aW9uSGFuZGxlcicsCiAgICAgICAgJ2dldENvdW50T2ZSZWNzJywKICAgICAg
            ICAnZ2V0U3RhdCcsCiAgICAgICAgJ2ltYWdlRXJyb3InLAogICAgICAgICdtYW51YWxWaWRlb0NsaWNrZWQnLAogICAgICAg
            ICdvbk9kYlJldHVybicsCiAgICAgICAgJ29uVmlkZW9DbGljaycsCiAgICAgICAgJ3BhZ2VyTG9hZCcsCiAgICAgICAgJ3Jl
            Y0NsaWNrZWQnLAogICAgICAgICdyZWZyZXNoU3BlY2lmaWNXaWRnZXQnLAogICAgICAgICdyZW5kZXJTcGFXaWRnZXRzJywK
            ICAgICAgICAncmVmcmVzaFdpZGdldCcsCiAgICAgICAgJ3JlbG9hZFdpZGdldCcsCiAgICAgICAgJ3Jlc2VhcmNoV2lkZ2V0
            JywKICAgICAgICAncmV0dXJuZWRFcnJvcicsCiAgICAgICAgJ3JldHVybmVkSHRtbERhdGEnLAogICAgICAgICdyZXR1cm5l
            ZElyZERhdGEnLAogICAgICAgICdyZXR1cm5lZEpzb25EYXRhJywKICAgICAgICAnc2Nyb2xsTG9hZCcsCiAgICAgICAgJ3No
            b3dEZXNjcmlwdGlvbicsCiAgICAgICAgJ3Nob3dSZWNJbklmcmFtZScsCiAgICAgICAgJ3VzZXJaYXBwaW5nTWVzc2FnZScs
            CiAgICAgICAgJ3phcHBpbmdGb3JtQWN0aW9uJwogICAgXTsKICAgIG9ici5leHRlcm4gPSB7CiAgICAgICAgdmlkZW86IHsK
            ICAgICAgICAgICAgZ2V0VmlkZW9SZWNzOiBub29wZm4sCiAgICAgICAgICAgIHZpZGVvQ2xpY2tlZDogbm9vcGZuCiAgICAg
            ICAgfQogICAgfTsKICAgIG1ldGhvZHMuZm9yRWFjaChmdW5jdGlvbihhKSB7CiAgICAgICAgb2JyLmV4dGVyblthXSA9IG5v
            b3BmbjsKICAgIH0pOwogICAgd2luZG93Lk9CUiA9IHdpbmRvdy5PQlIgfHwgb2JyOwp9KSgpOwo=
            """
        ),
        RedirectResource(
            name: "piano-analytics.js",
            mimeType: "text/javascript",
            base64: """
            c2VsZi5wYSA9IHsKICAgIGdldFZpc2l0b3JJZCgpIHsKICAgIH0sCiAgICBzZW5kRXZlbnQoKSB7CiAgICB9LAp9Owo=
            """
        ),
        RedirectResource(
            name: "popads-dummy.js",
            mimeType: "text/javascript",
            base64: """
            LyoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
            KioqKioqKioKCiAgICB1QmxvY2sgT3JpZ2luIC0gYSBicm93c2VyIGV4dGVuc2lvbiB0byBibG9jayByZXF1ZXN0cy4KICAg
            IENvcHlyaWdodCAoQykgMjAxOS1wcmVzZW50IFJheW1vbmQgSGlsbAoKICAgIFRoaXMgcHJvZ3JhbSBpcyBmcmVlIHNvZnR3
            YXJlOiB5b3UgY2FuIHJlZGlzdHJpYnV0ZSBpdCBhbmQvb3IgbW9kaWZ5CiAgICBpdCB1bmRlciB0aGUgdGVybXMgb2YgdGhl
            IEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGFzIHB1Ymxpc2hlZCBieQogICAgdGhlIEZyZWUgU29mdHdhcmUgRm91bmRh
            dGlvbiwgZWl0aGVyIHZlcnNpb24gMyBvZiB0aGUgTGljZW5zZSwgb3IKICAgIChhdCB5b3VyIG9wdGlvbikgYW55IGxhdGVy
            IHZlcnNpb24uCgogICAgVGhpcyBwcm9ncmFtIGlzIGRpc3RyaWJ1dGVkIGluIHRoZSBob3BlIHRoYXQgaXQgd2lsbCBiZSB1
            c2VmdWwsCiAgICBidXQgV0lUSE9VVCBBTlkgV0FSUkFOVFk7IHdpdGhvdXQgZXZlbiB0aGUgaW1wbGllZCB3YXJyYW50eSBv
            ZgogICAgTUVSQ0hBTlRBQklMSVRZIG9yIEZJVE5FU1MgRk9SIEEgUEFSVElDVUxBUiBQVVJQT1NFLiAgU2VlIHRoZQogICAg
            R05VIEdlbmVyYWwgUHVibGljIExpY2Vuc2UgZm9yIG1vcmUgZGV0YWlscy4KCiAgICBZb3Ugc2hvdWxkIGhhdmUgcmVjZWl2
            ZWQgYSBjb3B5IG9mIHRoZSBHTlUgR2VuZXJhbCBQdWJsaWMgTGljZW5zZQogICAgYWxvbmcgd2l0aCB0aGlzIHByb2dyYW0u
            ICBJZiBub3QsIHNlZSB7aHR0cDovL3d3dy5nbnUub3JnL2xpY2Vuc2VzL30uCgogICAgSG9tZTogaHR0cHM6Ly9naXRodWIu
            Y29tL2dvcmhpbGwvdUJsb2NrCiovCgooZnVuY3Rpb24oKSB7CiAgICAndXNlIHN0cmljdCc7CiAgICBkZWxldGUgd2luZG93
            LlBvcEFkczsKICAgIGRlbGV0ZSB3aW5kb3cucG9wbnM7CiAgICBPYmplY3QuZGVmaW5lUHJvcGVydGllcyh3aW5kb3csIHsK
            ICAgICAgICBQb3BBZHM6IHsgdmFsdWU6IHt9IH0sCiAgICAgICAgcG9wbnM6IHsgdmFsdWU6IHt9IH0KICAgIH0pOwp9KSgp
            Owo=
            """
        ),
        RedirectResource(
            name: "popads.js",
            mimeType: "text/javascript",
            base64: """
            LyoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
            KioqKioqKioKCiAgICB1QmxvY2sgT3JpZ2luIC0gYSBicm93c2VyIGV4dGVuc2lvbiB0byBibG9jayByZXF1ZXN0cy4KICAg
            IENvcHlyaWdodCAoQykgMjAxOS1wcmVzZW50IFJheW1vbmQgSGlsbAoKICAgIFRoaXMgcHJvZ3JhbSBpcyBmcmVlIHNvZnR3
            YXJlOiB5b3UgY2FuIHJlZGlzdHJpYnV0ZSBpdCBhbmQvb3IgbW9kaWZ5CiAgICBpdCB1bmRlciB0aGUgdGVybXMgb2YgdGhl
            IEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGFzIHB1Ymxpc2hlZCBieQogICAgdGhlIEZyZWUgU29mdHdhcmUgRm91bmRh
            dGlvbiwgZWl0aGVyIHZlcnNpb24gMyBvZiB0aGUgTGljZW5zZSwgb3IKICAgIChhdCB5b3VyIG9wdGlvbikgYW55IGxhdGVy
            IHZlcnNpb24uCgogICAgVGhpcyBwcm9ncmFtIGlzIGRpc3RyaWJ1dGVkIGluIHRoZSBob3BlIHRoYXQgaXQgd2lsbCBiZSB1
            c2VmdWwsCiAgICBidXQgV0lUSE9VVCBBTlkgV0FSUkFOVFk7IHdpdGhvdXQgZXZlbiB0aGUgaW1wbGllZCB3YXJyYW50eSBv
            ZgogICAgTUVSQ0hBTlRBQklMSVRZIG9yIEZJVE5FU1MgRk9SIEEgUEFSVElDVUxBUiBQVVJQT1NFLiAgU2VlIHRoZQogICAg
            R05VIEdlbmVyYWwgUHVibGljIExpY2Vuc2UgZm9yIG1vcmUgZGV0YWlscy4KCiAgICBZb3Ugc2hvdWxkIGhhdmUgcmVjZWl2
            ZWQgYSBjb3B5IG9mIHRoZSBHTlUgR2VuZXJhbCBQdWJsaWMgTGljZW5zZQogICAgYWxvbmcgd2l0aCB0aGlzIHByb2dyYW0u
            ICBJZiBub3QsIHNlZSB7aHR0cDovL3d3dy5nbnUub3JnL2xpY2Vuc2VzL30uCgogICAgSG9tZTogaHR0cHM6Ly9naXRodWIu
            Y29tL2dvcmhpbGwvdUJsb2NrCiovCgooZnVuY3Rpb24oKSB7CiAgICAndXNlIHN0cmljdCc7CiAgICBjb25zdCBtYWdpYyA9
            IFN0cmluZy5mcm9tQ2hhckNvZGUoRGF0ZS5ub3coKSAlIDI2ICsgOTcpICsKICAgICAgICAgICAgICAgICAgTWF0aC5mbG9v
            cihNYXRoLnJhbmRvbSgpICogOTgyNDUxNjUzICsgOTgyNDUxNjUzKS50b1N0cmluZygzNik7CiAgICBjb25zdCBvZSA9IHdp
            bmRvdy5vbmVycm9yOwogICAgd2luZG93Lm9uZXJyb3IgPSBmdW5jdGlvbihtc2csIHNyYywgbGluZSwgY29sLCBlcnJvcikg
            ewogICAgICAgIGlmICggdHlwZW9mIG1zZyA9PT0gJ3N0cmluZycgJiYgbXNnLmluZGV4T2YobWFnaWMpICE9PSAtMSApIHsg
            cmV0dXJuIHRydWU7IH0KICAgICAgICBpZiAoIG9lIGluc3RhbmNlb2YgRnVuY3Rpb24gKSB7CiAgICAgICAgICAgIHJldHVy
            biBvZShtc2csIHNyYywgbGluZSwgY29sLCBlcnJvcik7CiAgICAgICAgfQogICAgfS5iaW5kKCk7CiAgICBjb25zdCB0aHJv
            d01hZ2ljID0gZnVuY3Rpb24oKSB7IHRocm93IG5ldyBSZWZlcmVuY2VFcnJvcihtYWdpYyk7IH07CiAgICBkZWxldGUgd2lu
            ZG93LlBvcEFkczsKICAgIGRlbGV0ZSB3aW5kb3cucG9wbnM7CiAgICBPYmplY3QuZGVmaW5lUHJvcGVydGllcyh3aW5kb3cs
            IHsKICAgICAgICBQb3BBZHM6IHsgc2V0OiB0aHJvd01hZ2ljIH0sCiAgICAgICAgcG9wbnM6IHsgc2V0OiB0aHJvd01hZ2lj
            IH0KICAgIH0pOwp9KSgpOwo=
            """
        ),
        RedirectResource(
            name: "prebid-ads.js",
            mimeType: "text/javascript",
            base64: """
            LyoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
            KioqKioqKioKCiAgICB1QmxvY2sgT3JpZ2luIC0gYSBicm93c2VyIGV4dGVuc2lvbiB0byBibG9jayByZXF1ZXN0cy4KICAg
            IENvcHlyaWdodCAoQykgMjAyMi1wcmVzZW50IFJheW1vbmQgSGlsbAoKICAgIFRoaXMgcHJvZ3JhbSBpcyBmcmVlIHNvZnR3
            YXJlOiB5b3UgY2FuIHJlZGlzdHJpYnV0ZSBpdCBhbmQvb3IgbW9kaWZ5CiAgICBpdCB1bmRlciB0aGUgdGVybXMgb2YgdGhl
            IEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGFzIHB1Ymxpc2hlZCBieQogICAgdGhlIEZyZWUgU29mdHdhcmUgRm91bmRh
            dGlvbiwgZWl0aGVyIHZlcnNpb24gMyBvZiB0aGUgTGljZW5zZSwgb3IKICAgIChhdCB5b3VyIG9wdGlvbikgYW55IGxhdGVy
            IHZlcnNpb24uCgogICAgVGhpcyBwcm9ncmFtIGlzIGRpc3RyaWJ1dGVkIGluIHRoZSBob3BlIHRoYXQgaXQgd2lsbCBiZSB1
            c2VmdWwsCiAgICBidXQgV0lUSE9VVCBBTlkgV0FSUkFOVFk7IHdpdGhvdXQgZXZlbiB0aGUgaW1wbGllZCB3YXJyYW50eSBv
            ZgogICAgTUVSQ0hBTlRBQklMSVRZIG9yIEZJVE5FU1MgRk9SIEEgUEFSVElDVUxBUiBQVVJQT1NFLiAgU2VlIHRoZQogICAg
            R05VIEdlbmVyYWwgUHVibGljIExpY2Vuc2UgZm9yIG1vcmUgZGV0YWlscy4KCiAgICBZb3Ugc2hvdWxkIGhhdmUgcmVjZWl2
            ZWQgYSBjb3B5IG9mIHRoZSBHTlUgR2VuZXJhbCBQdWJsaWMgTGljZW5zZQogICAgYWxvbmcgd2l0aCB0aGlzIHByb2dyYW0u
            ICBJZiBub3QsIHNlZSB7aHR0cDovL3d3dy5nbnUub3JnL2xpY2Vuc2VzL30uCgogICAgSG9tZTogaHR0cHM6Ly9naXRodWIu
            Y29tL2dvcmhpbGwvdUJsb2NrCiovCgooZnVuY3Rpb24oKSB7CiAgICAndXNlIHN0cmljdCc7CiAgICB3aW5kb3cuY2FuUnVu
            QWRzID0gdHJ1ZTsKICAgIHdpbmRvdy5pc0FkQmxvY2tBY3RpdmUgPSBmYWxzZTsKfSkoKTsK
            """
        ),
        RedirectResource(
            name: "scorecardresearch_beacon.js",
            mimeType: "text/javascript",
            base64: """
            LyoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
            KioqKioqKioKCiAgICB1QmxvY2sgT3JpZ2luIC0gYSBicm93c2VyIGV4dGVuc2lvbiB0byBibG9jayByZXF1ZXN0cy4KICAg
            IENvcHlyaWdodCAoQykgMjAxOS1wcmVzZW50IFJheW1vbmQgSGlsbAoKICAgIFRoaXMgcHJvZ3JhbSBpcyBmcmVlIHNvZnR3
            YXJlOiB5b3UgY2FuIHJlZGlzdHJpYnV0ZSBpdCBhbmQvb3IgbW9kaWZ5CiAgICBpdCB1bmRlciB0aGUgdGVybXMgb2YgdGhl
            IEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGFzIHB1Ymxpc2hlZCBieQogICAgdGhlIEZyZWUgU29mdHdhcmUgRm91bmRh
            dGlvbiwgZWl0aGVyIHZlcnNpb24gMyBvZiB0aGUgTGljZW5zZSwgb3IKICAgIChhdCB5b3VyIG9wdGlvbikgYW55IGxhdGVy
            IHZlcnNpb24uCgogICAgVGhpcyBwcm9ncmFtIGlzIGRpc3RyaWJ1dGVkIGluIHRoZSBob3BlIHRoYXQgaXQgd2lsbCBiZSB1
            c2VmdWwsCiAgICBidXQgV0lUSE9VVCBBTlkgV0FSUkFOVFk7IHdpdGhvdXQgZXZlbiB0aGUgaW1wbGllZCB3YXJyYW50eSBv
            ZgogICAgTUVSQ0hBTlRBQklMSVRZIG9yIEZJVE5FU1MgRk9SIEEgUEFSVElDVUxBUiBQVVJQT1NFLiAgU2VlIHRoZQogICAg
            R05VIEdlbmVyYWwgUHVibGljIExpY2Vuc2UgZm9yIG1vcmUgZGV0YWlscy4KCiAgICBZb3Ugc2hvdWxkIGhhdmUgcmVjZWl2
            ZWQgYSBjb3B5IG9mIHRoZSBHTlUgR2VuZXJhbCBQdWJsaWMgTGljZW5zZQogICAgYWxvbmcgd2l0aCB0aGlzIHByb2dyYW0u
            ICBJZiBub3QsIHNlZSB7aHR0cDovL3d3dy5nbnUub3JnL2xpY2Vuc2VzL30uCgogICAgSG9tZTogaHR0cHM6Ly9naXRodWIu
            Y29tL2dvcmhpbGwvdUJsb2NrCiovCgooZnVuY3Rpb24oKSB7CiAgICAndXNlIHN0cmljdCc7CiAgICB3aW5kb3cuQ09NU0NP
            UkUgPSB7CiAgICAgICAgcHVyZ2U6IGZ1bmN0aW9uKCkgewogICAgICAgICAgICB3aW5kb3cuX2NvbXNjb3JlID0gW107CiAg
            ICAgICAgfSwKICAgICAgICBiZWFjb246IGZ1bmN0aW9uKCkgewogICAgICAgIH0KICAgIH07Cn0pKCk7Cg==
            """
        ),
        RedirectResource(
            name: "sensors-analytics.js",
            mimeType: "text/javascript",
            base64: """
            LyoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
            KioqKioqKioKCiAgICB1QmxvY2sgT3JpZ2luIC0gYSBicm93c2VyIGV4dGVuc2lvbiB0byBibG9jayByZXF1ZXN0cy4KICAg
            IENvcHlyaWdodCAoQykgMjAyNS1wcmVzZW50IFJheW1vbmQgSGlsbAoKICAgIFRoaXMgcHJvZ3JhbSBpcyBmcmVlIHNvZnR3
            YXJlOiB5b3UgY2FuIHJlZGlzdHJpYnV0ZSBpdCBhbmQvb3IgbW9kaWZ5CiAgICBpdCB1bmRlciB0aGUgdGVybXMgb2YgdGhl
            IEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGFzIHB1Ymxpc2hlZCBieQogICAgdGhlIEZyZWUgU29mdHdhcmUgRm91bmRh
            dGlvbiwgZWl0aGVyIHZlcnNpb24gMyBvZiB0aGUgTGljZW5zZSwgb3IKICAgIChhdCB5b3VyIG9wdGlvbikgYW55IGxhdGVy
            IHZlcnNpb24uCgogICAgVGhpcyBwcm9ncmFtIGlzIGRpc3RyaWJ1dGVkIGluIHRoZSBob3BlIHRoYXQgaXQgd2lsbCBiZSB1
            c2VmdWwsCiAgICBidXQgV0lUSE9VVCBBTlkgV0FSUkFOVFk7IHdpdGhvdXQgZXZlbiB0aGUgaW1wbGllZCB3YXJyYW50eSBv
            ZgogICAgTUVSQ0hBTlRBQklMSVRZIG9yIEZJVE5FU1MgRk9SIEEgUEFSVElDVUxBUiBQVVJQT1NFLiAgU2VlIHRoZQogICAg
            R05VIEdlbmVyYWwgUHVibGljIExpY2Vuc2UgZm9yIG1vcmUgZGV0YWlscy4KCiAgICBZb3Ugc2hvdWxkIGhhdmUgcmVjZWl2
            ZWQgYSBjb3B5IG9mIHRoZSBHTlUgR2VuZXJhbCBQdWJsaWMgTGljZW5zZQogICAgYWxvbmcgd2l0aCB0aGlzIHByb2dyYW0u
            ICBJZiBub3QsIHNlZSB7aHR0cDovL3d3dy5nbnUub3JnL2xpY2Vuc2VzL30uCgogICAgSG9tZTogaHR0cHM6Ly9naXRodWIu
            Y29tL2dvcmhpbGwvdUJsb2NrCiovCgooZnVuY3Rpb24oKSB7CiAgICAndXNlIHN0cmljdCc7CiAgICBjb25zdCBub29wZm4g
            PSBmdW5jdGlvbigpIHsKICAgIH07CiAgICB3aW5kb3cuc2Vuc29yc0RhdGFBbmFseXRpYzIwMTUwNSA9IHsKICAgICAgICBp
            bml0OiBub29wZm4sCiAgICAgICAgcXVpY2s6IG5vb3BmbiwKICAgICAgICByZWdpc3Rlcjogbm9vcGZuLAogICAgICAgIHRy
            YWNrOiBub29wZm4sCiAgICB9Owp9KSgpOwo=
            """
        ),
    ]

    static let resourceAliases: [String: String] = [
        "1x1-transparent.gif": "1x1.gif",
        "2x2-transparent.png": "2x2.png",
        "32x32-transparent.png": "32x32.png",
        "3x2-transparent.png": "3x2.png",
        "abp-resource:blank-js": "noop.js",
        "abp-resource:blank-mp3": "noop-0.1s.mp3",
        "abp-resource:blank-mp4": "noop-1s.mp4",
        "amazon-adsystem.com/aax2/amzn_ads.js": "amazon_ads.js",
        "ampproject.org/v0.js": "ampproject_v0.js",
        "doubleclick.net/instream/ad_status.js": "doubleclick_instream_ad_status.js",
        "fuckadblock.js-3.2.0": "nofab.js",
        "google-analytics.com/analytics.js": "google-analytics_analytics.js",
        "google-analytics.com/cx/api.js": "google-analytics_cx_api.js",
        "google-analytics.com/ga.js": "google-analytics_ga.js",
        "google-analytics.com/inpage_linkid.js": "google-analytics_inpage_linkid.js",
        "google-ima3": "google-ima.js",
        "googlesyndication-adsbygoogle": "googlesyndication_adsbygoogle.js",
        "googlesyndication.com/adsbygoogle.js": "googlesyndication_adsbygoogle.js",
        "googletagmanager.com/gtm.js": "google-analytics_analytics.js",
        "googletagmanager_gtm.js": "google-analytics_analytics.js",
        "googletagservices-gpt": "googletagservices_gpt.js",
        "googletagservices.com/gpt.js": "googletagservices_gpt.js",
        "noop-vmap1.0.xml": "noop-vmap1.xml",
        "noopframe": "noop.html",
        "noopjs": "noop.js",
        "noopjson": "noop.json",
        "noopmp3-0.1s": "noop-0.1s.mp3",
        "noopmp4-1s": "noop-1s.mp4",
        "nooptext": "noop.txt",
        "noopvast-2.0": "noop-vast2.xml",
        "noopvast-3.0": "noop-vast3.xml",
        "noopvast-4.0": "noop-vast4.xml",
        "noopvmap-1.0": "noop-vmap1.xml",
        "popads.net.js": "popads.js",
        "prevent-popads-net.js": "popads.js",
        "scorecardresearch.com/beacon.js": "scorecardresearch_beacon.js",
        "silent-noeval.js": "noeval-silent.js",
        "static.chartbeat.com/chartbeat.js": "chartbeat.js",
        "widgets.outbrain.com/outbrain.js": "outbrain-widget.js",
    ]
}
