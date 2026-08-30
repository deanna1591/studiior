import type { Config } from "tailwindcss";

/**
 * The palette points at the custom properties in globals.css rather than
 * restating the hexes, so there is one place a colour is defined and one place
 * its contrast was argued for.
 */
export default {
  content: ["./app/**/*.{ts,tsx}", "./components/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        paper: "var(--paper)",
        surface: "var(--surface)",
        ink: { DEFAULT: "var(--ink)", 2: "var(--ink-2)", 3: "var(--ink-3)" },
        line: { DEFAULT: "var(--line)", 2: "var(--line-2)" },
        lime: {
          DEFAULT: "var(--lime)",
          tint: "var(--lime-tint)",
          text: "var(--lime-text)",
          text2: "var(--lime-text-2)",
        },
        amber: { DEFAULT: "var(--amber)", tint: "var(--amber-tint)" },
        coral: {
          DEFAULT: "var(--coral)",
          fill: "var(--coral-fill)",
          tint: "var(--coral-tint)",
        },
      },
      fontFamily: {
        sans: ["var(--font-karla)", "ui-sans-serif", "system-ui", "sans-serif"],
        display: ["var(--font-archivo)", "ui-sans-serif", "system-ui", "sans-serif"],
        mono: ["var(--font-mono)", "ui-monospace", "monospace"],
      },
      spacing: { rail: "var(--rail-w)" },
      borderRadius: { DEFAULT: "3px", sm: "2px", md: "4px" },
    },
  },
} satisfies Config;
