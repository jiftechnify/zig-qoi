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

    // decode the QOI image
    const resPtr = instance.exports.decode(fileInputPtr, fileSize);
    if (resPtr === 0) { // null pointer
      console.error('failed to decode QOI image')
      return;
    }

    let res;
    try {
      // get the result
      const resBuf = getWasmMemoryDataView(resPtr, 20);
      res = getDecodeResult(resBuf);
      console.log(res);

      // paint the decoded image
      const img = new ImageData(new Uint8ClampedArray(getWasmMemory().buffer, res.imgPtr, res.imgLen), res.width, res.height);
      const canvas = document.getElementById("decoded-image")
      canvas.width = res.width;
      canvas.height = res.height;
      canvas.getContext("2d"). putImageData(img, 0, 0);
      document.getElementById("decode-result").style.display = "block";
    } finally {
      instance.exports.freeBuffer(res.imgPtr, res.imgLen);
    }
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

async function onClickEncode() {
  const files = document.getElementById("enc-file").files;
  if (files.length === 0) {
    console.log("no file selected");
    return;
  }

  const srcImgFile = files[0];
  const imgData = await decodeImage(srcImgFile);

  const imgLen = imgData.data.byteLength;
  const imgInputPtr = instance.exports.allocateBuffer(imgLen);
  if (imgInputPtr === 0) {
    return;
  }

  try {
    const imgInputBuf = getWasmMemorySlice(imgInputPtr, imgLen);
    imgInputBuf.set(imgData.data);
    
    const resPtr = instance.exports.encode(imgData.width, imgData.height, imgInputPtr, imgLen);
    if (resPtr === 0) {
      console.error('failed to encode image to QOI');
      return;
    }
    
    let res;
    try {
      // get result
      const resBuf = getWasmMemoryDataView(resPtr, 8);
      res = getEncodeResult(resBuf);

      // write to file
      const stem = srcImgFile.name.substring(0, srcImgFile.name.lastIndexOf("."));
      downloadBinaryFile(getWasmMemorySlice(res.buf, res.len), `${stem}.qoi`);
    } finally {
      instance.exports.freeBuffer(res.buf, res.len);
    }
  } finally {
    instance.exports.freeBuffer(imgInputPtr, imgLen);
  }
}

/**
 * Extracts result of qoi.encode
 * 
 * @param {DataView} resBuf result buffer of decode
 */
function getEncodeResult(resBuf) {
  return {
    buf: resBuf.getUint32(0, true),
    len: resBuf.getUint32(4, true),
  };
}

/**
 * Decodes image file and return as an ImageData
 * 
 * @param {File} file
 * @returns {Promise<ImageData>}e
 */
async function decodeImage(file) {
  const readAsDataURL = (f) => {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = (e) => {
        resolve(e.target.result);
      };
      reader.onerror = (e) => {
        reject(e.target.error);
      };
      reader.readAsDataURL(f);
    });
  };

  const getImageData = (dataUrl) => {
    return new Promise((resolve, reject) => {
      const canvas = document.getElementById("canvas");
      const ctx = canvas.getContext("2d");

      const img = new Image();
      img.addEventListener("load", () => {
        canvas.width = img.width;
        canvas.height = img.height;
        ctx.drawImage(img, 0, 0);
        resolve(ctx.getImageData(0, 0, img.width, img.height));
      })
      img.addEventListener("error", (e) => {
        reject(e);
      })
      img.src = dataUrl;
    })
  }

  const dataUrl = await readAsDataURL(file);
  return getImageData(dataUrl);
}

/**
 * Downloads the binary data as a file
 * 
 * @param {Uint8Array} bytes
 * @param {string} filename
 */
function downloadBinaryFile(bytes, filename) {
  const blob = new Blob([bytes]);
  const dataUrl = URL.createObjectURL(blob);
  const a = document.createElement("a");
  document.body.appendChild(a);
  a.download = filename;
  a.href = dataUrl;
  a.click();
  a.remove();
  setTimeout(() => {
    URL.revokeObjectURL(dataUrl);
  }, 1e4);
}
