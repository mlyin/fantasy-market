// Bridge to the iOS shell. In a plain browser `native.available` is false and posts are dropped.
//
// Web -> native: ready, connect, disconnect, capture, scanResult, position, setMock, lensPreview
// Native -> web: status, photo, frame, command
const handler = globalThis.webkit?.messageHandlers?.chessLens;

export const native = {
  available: Boolean(handler),
  /** @type {((msg: any) => void) | null} */
  onMessage: null,
  post(message) {
    if (handler) handler.postMessage(message);
  },
};

globalThis.ChessLensNative = {
  receive(message) {
    try {
      native.onMessage?.(message);
    } catch (err) {
      console.error('native message failed', message?.type, err);
    }
  },
};
