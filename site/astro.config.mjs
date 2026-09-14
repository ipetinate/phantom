// @ts-check
import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";
import sitemap from "@astrojs/sitemap";
import icon from "astro-icon";

const SITE = "https://phantom.nertec.com.br";
const OG_ALT =
  "Phantom: a macOS terminal with a sidebar of grouped projects beside an editor and a terminal.";

export default defineConfig({
  site: "https://phantom.nertec.com.br",
  base: "/",
  trailingSlash: "always",
  integrations: [
    starlight({
      title: "Phantom",
      description:
        "A Ghostty-powered terminal for macOS with a sidebar, an editor, git, worktrees, language servers, agents and an extension store.",
      logo: {
        light: "./src/assets/phantom-mark-dark.svg",
        dark: "./src/assets/phantom-mark.svg",
        replacesTitle: false,
      },
      favicon: "/favicon.ico",
      /* Starlight writes og:title, og:description, og:url and og:type per
         page; these are the rest, the same on every one of them. */
      head: [
        { tag: "meta", attrs: { property: "og:image", content: `${SITE}/og.jpg` } },
        { tag: "meta", attrs: { property: "og:image:secure_url", content: `${SITE}/og.jpg` } },
        { tag: "meta", attrs: { property: "og:image:type", content: "image/jpeg" } },
        { tag: "meta", attrs: { property: "og:image:width", content: "1200" } },
        { tag: "meta", attrs: { property: "og:image:height", content: "675" } },
        { tag: "meta", attrs: { property: "og:image:alt", content: OG_ALT } },
        { tag: "meta", attrs: { name: "twitter:image", content: `${SITE}/og.jpg` } },
        { tag: "meta", attrs: { name: "twitter:image:alt", content: OG_ALT } },
        { tag: "link", attrs: { rel: "icon", href: "/favicon-32.png", type: "image/png", sizes: "32x32" } },
        { tag: "link", attrs: { rel: "icon", href: "/favicon-16.png", type: "image/png", sizes: "16x16" } },
        { tag: "link", attrs: { rel: "apple-touch-icon", href: "/apple-touch-icon.png", sizes: "180x180" } },
        { tag: "link", attrs: { rel: "manifest", href: "/site.webmanifest" } },
        {
          tag: "meta",
          attrs: {
            name: "theme-color",
            content: "#060608",
            media: "(prefers-color-scheme: dark)",
          },
        },
        {
          tag: "meta",
          attrs: {
            name: "theme-color",
            content: "#fbfbf9",
            media: "(prefers-color-scheme: light)",
          },
        },
        { tag: "meta", attrs: { name: "color-scheme", content: "dark light" } },
        { tag: "meta", attrs: { name: "author", content: "Isac Petinate" } },
        { tag: "meta", attrs: { name: "application-name", content: "Phantom" } },
        { tag: "meta", attrs: { name: "apple-mobile-web-app-title", content: "Phantom" } },
        { tag: "meta", attrs: { name: "msapplication-TileColor", content: "#060608" } },
        { tag: "meta", attrs: { name: "robots", content: "index, follow, max-image-preview:large" } },
      ],
      customCss: ["./src/styles/docs.css"],
      expressiveCode: { themes: ["dracula", "github-light"] },
      social: [
        {
          icon: "github",
          label: "GitHub",
          href: "https://github.com/ipetinate/phantom",
        },
      ],
      editLink: {
        baseUrl: "https://github.com/ipetinate/phantom/edit/main/site/",
      },
      defaultLocale: "root",
      locales: {
        root: { label: "English", lang: "en" },
        "pt-br": { label: "Português", lang: "pt-BR" },
      },
      sidebar: [
        {
          label: "Start",
          translations: { "pt-BR": "Começar" },
          items: [
            "docs/install",
            "docs/first-run",
            "docs/build-from-source",
          ],
        },
        {
          label: "The window",
          translations: { "pt-BR": "A janela" },
          items: [
            "docs/sidebar-and-groups",
            "docs/agents",
            "docs/editor",
            "docs/keybindings",
          ],
        },
        {
          label: "Code",
          translations: { "pt-BR": "Código" },
          items: [
            "docs/language-servers",
            "docs/git",
            "docs/worktrees",
          ],
        },
        {
          label: "Extend",
          translations: { "pt-BR": "Estender" },
          items: [
            "docs/extensions",
            "docs/extensions-authoring",
            "docs/mcp",
            "docs/themes-and-icons",
          ],
        },
        {
          label: "Reference",
          translations: { "pt-BR": "Referência" },
          items: ["docs/configuration", "docs/updates"],
        },
      ],
      lastUpdated: false,
      credits: false,
    }),
    sitemap(),
    icon({ include: { "fa6-brands": ["apple", "linux"] } }),
  ],
});
