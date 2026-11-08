// The vendored brand fonts (public/fonts/invoice + /brand). Family names match
// the brand spec's font list. One @font-face block, shared by the brand-kit
// preview and the schedule-post renderer so a learned post and its preview draw
// in exactly the same faces. html-to-image inlines these when exporting a PNG.
export const BRAND_FONT_FACES = `
@font-face{font-family:'Space Grotesk';src:url('/fonts/invoice/SpaceGrotesk-Regular.ttf') format('truetype');font-weight:400;font-display:swap}
@font-face{font-family:'Space Grotesk';src:url('/fonts/invoice/SpaceGrotesk-Bold.ttf') format('truetype');font-weight:700;font-display:swap}
@font-face{font-family:'Space Mono';src:url('/fonts/invoice/SpaceMono-Regular.ttf') format('truetype');font-weight:400;font-display:swap}
@font-face{font-family:'Space Mono';src:url('/fonts/invoice/SpaceMono-Bold.ttf') format('truetype');font-weight:700;font-display:swap}
@font-face{font-family:'Bodoni Moda';src:url('/fonts/invoice/BodoniModa-Regular.ttf') format('truetype');font-weight:400;font-display:swap}
@font-face{font-family:'Instrument Serif';src:url('/fonts/brand/InstrumentSerif-Regular.ttf') format('truetype');font-weight:400;font-display:swap}
@font-face{font-family:'Playfair Display';src:url('/fonts/brand/PlayfairDisplay.ttf') format('truetype');font-weight:100 900;font-display:swap}
@font-face{font-family:'Manrope';src:url('/fonts/brand/Manrope.ttf') format('truetype');font-weight:100 900;font-display:swap}
@font-face{font-family:'Inter';src:url('/fonts/brand/Inter.ttf') format('truetype');font-weight:100 900;font-display:swap}
@font-face{font-family:'DM Sans';src:url('/fonts/brand/DMSans.ttf') format('truetype');font-weight:100 900;font-display:swap}
@font-face{font-family:'Fraunces';src:url('/fonts/brand/Fraunces.ttf') format('truetype');font-weight:100 900;font-display:swap}
@font-face{font-family:'Cormorant';src:url('/fonts/brand/Cormorant.ttf') format('truetype');font-weight:100 900;font-display:swap}
@font-face{font-family:'Nothing You Could Do';src:url('/fonts/brand/NothingYouCouldDo.ttf') format('truetype');font-weight:400;font-display:swap}
`;
