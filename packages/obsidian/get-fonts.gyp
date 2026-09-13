# node-gyp build file for get-fonts.c; build() copies it to binding.gyp.
{
  "targets": [
    {
      "target_name": "binding",
      "sources": ["get-fonts.c"],
      "cflags": ["<!@(pkg-config --cflags fontconfig)"],
      "libraries": ["<!@(pkg-config --libs fontconfig)"]
    }
  ]
}
