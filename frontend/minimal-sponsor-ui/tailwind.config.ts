import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        ink: {
          950: "#060b14",
          900: "#0b1322",
          800: "#11203a",
        },
        mint: {
          400: "#43e5b8",
          500: "#15bf93",
        },
        rose: {
          400: "#ff6b81",
        },
        gold: {
          400: "#ffd166",
        },
      },
      boxShadow: {
        glow: "0 0 0 1px rgba(255,255,255,0.08), 0 12px 48px rgba(14, 165, 233, 0.12)",
      },
      fontFamily: {
        heading: ["'Space Grotesk'", "sans-serif"],
        body: ["'Instrument Sans'", "sans-serif"],
      },
    },
  },
  plugins: [],
};

export default config;
