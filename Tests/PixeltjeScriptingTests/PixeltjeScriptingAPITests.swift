import PixeltjeScripting
import Testing

@Test func embeddedJavascriptAPIStaysAtVersionOneForThisSlice() {
  // Start-inpainting is deliberately protocol-neutral/MCP-only until the
  // maintainer explicitly opts into a JavaScript API addition.
  #expect(PixeltjeScriptAPI.currentVersion == 1)
}
