import type { Metadata } from "next";
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

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${archivo.variable} ${karla.variable} ${mono.variable}`}>
      <body>{children}</body>
    </html>
  );
}
