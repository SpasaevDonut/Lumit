// @ts-check
import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";

// docs.lumitlab.com — its own Cloudflare Pages project so the subdomain is a real
// deployment target rather than a redirect. Shares the marketing site's palette.
export default defineConfig({
  site: "https://docs.lumitlab.com",
  integrations: [
    starlight({
      title: "Lumit docs",
      description: "Documentation for Lumit, the native motion-graphics and compositing editor.",
      logo: { src: "./src/assets/lumit-mark.svg", alt: "Lumit" },
      favicon: "/lumit-mark.svg",
      customCss: ["./src/styles/theme.css"],
      social: [
        { icon: "github", label: "GitHub", href: "https://github.com/luminalmvm/Lumit" },
      ],
      editLink: {
        baseUrl: "https://github.com/luminalmvm/Lumit/edit/main/web-docs/",
      },
      sidebar: [
        { label: "Start here", autogenerate: { directory: "start" } },
        { label: "Editing", autogenerate: { directory: "editing" } },
        { label: "Reference", autogenerate: { directory: "reference" } },
      ],
    }),
  ],
});
