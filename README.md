# zoi
An [QOI](https://github.com/phoboslab/qoi) ("Quite OK Image Format") encoder/decoder implementation written in Zig.

This project is mainly for the purpose of learning Zig.

## qoiconv
This project includes *qoiconv* - a CLI tool for converting image files to QOI format.

Usage:

```sh
zig build qoiconv -- <path to image file>
```

It uses [zigimg](https://github.com/zigimg/zigimg) for decoding image files.  You can convert only images in formats which zigimg can decode.


## Wasm
This library can be used as a Wasm module. 

Steps to run the Wasm sample application:

```sh
cd wasm_sample
npm run start
# open http://localhost:8080 in your browser and you'll find the sample app!
```
