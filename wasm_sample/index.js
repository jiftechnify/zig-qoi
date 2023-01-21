const importObj = {
  env: {
    console_logger: (level, ptr, len) => g_logger.logger(level, ptr, len),
  },
};

/** @type {WebAssembly.Instance | undefined} */
let instance = undefined;
(async () => {
  instance = (
    await WebAssembly.instantiateStreaming(fetch("qoi.wasm"), importObj)
  ).instance;
})();

// credits: https://github.com/ousttrue/zig-opengl-wasm
const getWasmMemory = () => new DataView(instance.exports.memory.buffer);
const getWasmMemorySlice = (ptr, len) => new Uint8Array(getWasmMemory().buffer, ptr, len);
const getWasmMemoryDataView = (ptr, len) => new DataView(getWasmMemory().buffer, ptr, len);

const memToString = (ptr, len) => {
  let array = null;
  if (len) {
    array = getWasmMemorySlice(ptr, len);
  } else {
    // zero terminated
    let i = 0;
    const buffer = new Uint8Array(getWasmMemory().buffer, ptr);
    for (; i < buffer.length; ++i) {
      if (buffer[i] == 0) {
        break;
      }
    }
    array = getWasmMemorySlice(ptr, i);
  }
  const decoder = new TextDecoder();
  const text = decoder.decode(array);
  return text;
};

class Logger {
  constructor() {
    this.buffer = [];
  }

  logger(severity, ptr, len) {
    this.push(severity, memToString(ptr, len));
  }

  push(severity, last) {
    this.buffer.push(last);
    if (last.length > 0 && last[last.length - 1] == "\n") {
      const message = this.buffer.join("");
      this.buffer = [];
      switch (severity) {
        case 0:
          console.error(message);
          break;

        case 1:
          console.warn(message);
          break;

        case 2:
          console.info(message);
          break;

        default:
          console.debug(message);
          break;
      }
    }
  }
}
const g_logger = new Logger();

async function onClickDecode() {
  const files = document.getElementById("qoi-file").files;
  if (files.length === 0) {
    console.log("no file selected");
    return;
  }
  const fileBuf = new Uint8Array(await files[0].arrayBuffer());
  const fileSize = fileBuf.byteLength;
  
  const fileInputPtr = instance.exports.allocateBuffer(fileSize);
  if (fileInputPtr === 0) { // null pointer
    return;
  }
  
  try {
    // copy file data to wasm memory
    const fileInputBuf = getWasmMemorySlice(fileInputPtr, fileSize);
    fileInputBuf.set(fileBuf);

    // decode QOI image
    const ptrRes = instance.exports.decode(fileInputPtr, fileSize);

    if (ptrRes === 0) { // null pointer
      console.error('failed to decode QOI image')
      return;
    }

    // get result
    const resBuf = getWasmMemoryDataView(ptrRes, 20);
    const res = getDecodeResult(resBuf);
    console.log(res);

    const img = new ImageData(new Uint8ClampedArray(getWasmMemory().buffer, res.imgPtr, res.imgLen), res.width, res.height);
    const canvas = document.getElementById("decoded-image")
    canvas.width = res.width;
    canvas.height = res.height;
    canvas.getContext("2d"). putImageData(img, 0, 0);
  } finally {
    instance.exports.freeBuffer(fileInputPtr, fileSize);
  }
}

/**
 * extract result of qoi.decode
 * 
 * @param {DataView} resBuf result buffer of decode
 */
function getDecodeResult(resBuf) {
  return {
    width: resBuf.getUint32(0,true),
    height: resBuf.getUint32(4, true),
    numChannels: resBuf.getUint8(8, true),
    colorspace: resBuf.getUint8(9, true),
    imgPtr: resBuf.getUint32(12, true),
    imgLen: resBuf.getUint32(16, true),
  }
}
