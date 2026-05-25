import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "FocusFrame - Free macOS screen recorder",
  description:
    "FocusFrame is a free native macOS screen recorder for polished product demos, tutorials, course videos, and social clips.",
  openGraph: {
    title: "FocusFrame",
    description:
      "Free native macOS screen recording with automatic zooms, cursor polish, captions, styled exports, and local-first editing.",
    type: "website",
  },
  icons: {
    icon: [{ url: "/icon.png", sizes: "512x512", type: "image/png" }],
    apple: [{ url: "/apple-icon.png", sizes: "180x180", type: "image/png" }],
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
