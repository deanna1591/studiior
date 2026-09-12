import type { Metadata, Viewport } from "next";
import { Archivo, Karla, IBM_Plex_Mono } from "next/font/google";
import "./globals.css";

// Archivo carries a wdth axis (62–125); the brand sits at 112. Loading the
// axis is what makes that settable — without it the family ships at 100 and
// font-variation-settings has nothing to move.
const archivo = Archivo({
  subsets: ["latin"],
  axes: ["wdth"],
  variable: "--font-archivo",
  display: "swap",
});
const karla = Karla({ subsets: ["latin"], variable: "--font-karla", display: "swap" });
const mono = IBM_Plex_Mono({
  subsets: ["latin"],
  weight: ["400", "500"],
  variable: "--font-mono",
  display: "swap",
});

export const metadata: Metadata = { title: "Studiior" };

// viewport-fit=cover is what makes env(safe-area-inset-*) non-zero on a
// notched iPhone. Without it the tab bar's and .m-scroll's inset padding —
// written long ago — resolve to 0 and the bar sits under the home indicator.
// Harmless on the staff app, which is desktop. Zoom is left enabled: disabling
// it to stop input-focus zoom is an accessibility cost this app will not pay.
export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${archivo.variable} ${karla.variable} ${mono.variable}`}>
      <body>{children}</body>
    </html>
  );
}
