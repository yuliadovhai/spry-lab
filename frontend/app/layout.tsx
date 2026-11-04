import type { Metadata } from "next";
import { Fraunces, Geist_Mono, Nunito } from "next/font/google";

import { Providers } from "@/components/providers";
import { Toaster } from "@/components/ui/sonner";

import "./globals.css";

/* Warm theme: a rounded sans for the UI, a soft serif for headings. */
const nunito = Nunito({
  variable: "--font-notion-sans",
  subsets: ["latin", "cyrillic"],
  display: "swap",
});

const fraunces = Fraunces({
  variable: "--font-display",
  subsets: ["latin"],
  display: "swap",
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "Spry",
  description: "Where your team's meeting time goes",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="en"
      className={`${nunito.variable} ${fraunces.variable} ${geistMono.variable} h-full antialiased`}
    >
      {/* Extensions such as Grammarly stamp attributes on <body> before React
          hydrates; this silences that one-level mismatch only. */}
      <body className="flex min-h-full flex-col" suppressHydrationWarning>
        <Providers>
          {children}
          <Toaster />
        </Providers>
      </body>
    </html>
  );
}
