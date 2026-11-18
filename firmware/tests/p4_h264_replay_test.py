"""Compile real renderer replay functions against an intentionally mutating decoder."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def function(source, name):
    returns = "void" if name.startswith("reset_h264_decoder") else "bool"
    start = source.index("static " + returns + " " + name + "(")
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def test_mutating_decoder_cannot_damage_cached_stream():
    source = (ROOT / "main/pet_p4_renderer.c").read_text()
    declarations = source[source.index("static esp_h264_dec_handle_t g_h264_decoder;"):source.index("static uint8_t *g_h264_ppa_input;")]
    functions = "\n".join(function(source, name) for name in [
        "reset_h264_decoder", "reset_h264_decoder_traced", "reset_h264_decoder_measured", "start_h264_decoder_role", "decode_next_h264_frame_role", "start_h264_decoder", "decode_next_h264_frame",
    ])
    harness = (ROOT / "tests/p4_h264_replay_test.c").read_text()
    with tempfile.TemporaryDirectory() as tmp:
        test = Path(tmp) / "replay.c"
        binary = Path(tmp) / "replay"
        test.write_text(harness.replace("/* RENDERER_IMPLEMENTATION */", declarations + '\n' + functions))
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined", "-I", str(ROOT / "main"), str(test), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


def test_h264_render_uses_private_replay_buffer():
    source = (ROOT / "main/pet_p4_renderer.c").read_text()
    decode = function(source, "decode_next_h264_frame_role")
    assert 'decode_next_h264_frame_role(width,height,true,&g_last_decode_us,NULL)' in function(source,'decode_next_h264_frame')
    assert ".buffer = g_h264_work_stream + g_h264_stream_offset" in decode
    assert "(uint8_t *) (stream +" not in decode
    assert "start_h264_decoder(fs_path, stream->bytes, stream->size)" in source
    assert "decode_next_h264_frame(asset->width, asset->height)" in source
    start = function(source, "start_h264_decoder_role")
    assert 'start_h264_decoder_role(fs_path,stream,stream_size,&g_render_trace,NULL)' in function(source,'start_h264_decoder')
    assert "stream_size > PET_P4_ASSET_CACHE_MAX_FILE_BYTES" in start
    assert "MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT" in start


def test_wifi6_v3_wide_luma_filter_routes_all_columns_to_the_edge_filter(tmp_path):
    config = (ROOT / 'platformio.ini').read_text()
    wifi6_v3 = config.split('[env:esp32_p4_wifi6_system_settings_v3]', 1)[1].split('\n[', 1)[0]
    assert '-DPET_P4_H264_HOR_LUMA_EDGE_FALLBACK=1' in wifi6_v3
    assert '-Wl,--wrap=espFilterHorLuma_bS123' in wifi6_v3
    assert '-DPET_P4_H264_PANIC_TRACE=1' in wifi6_v3
    assert '-DPET_P4_H264_SERIAL_DECODE=1' in wifi6_v3
    assert '-Wl,--wrap=h264bsdAlloc' in wifi6_v3

    renderer = (ROOT / 'main/pet_p4_renderer.c').read_text()
    wrapper = renderer.split('#if PET_P4_H264_HOR_LUMA_EDGE_FALLBACK\n', 1)[1].split('#endif', 1)[0]
    source = tmp_path / 'luma.c'
    source.write_text('#include <stdint.h>\n#include <assert.h>\n#define IRAM_ATTR\n' + wrapper + r'''
static uint8_t pixels[16];
static uint32_t alpha = 27, beta = 8;
static unsigned columns;
void espFilterHorLumaEdge(uint8_t *p, uint32_t *a, uint32_t *b, uint32_t tc0, uint32_t stride) {
  assert(p == pixels + columns && a == &alpha && b == &beta && tc0 == 3 && stride == 640);
  columns += 4;
}
int main(void) {
  __wrap_espFilterHorLuma_bS123(pixels, &alpha, &beta, 3, 640);
  assert(columns == 16);
}
''')
    binary = tmp_path / 'luma'
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined',
                    str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)


def test_wifi6_v3_allocator_forces_serial_decode(tmp_path):
    renderer = (ROOT / 'main/pet_p4_renderer.c').read_text()
    start = renderer.index('extern h264bsd_hd_t __real_h264bsdAlloc')
    wrapper = renderer[start:renderer.index('#endif', start)]
    source = tmp_path / 'serial.c'
    source.write_text(r'''
#include <stddef.h>
#include <stdint.h>
#include <assert.h>
typedef void *h264bsd_hd_t;
typedef struct {uint32_t dualTaskEnable, dualTaskCore, dualTaskPriority;} h264bsd_cfg_t;
''' + wrapper + r'''
static unsigned calls;
static h264bsd_cfg_t original = {1, 1, 17};
h264bsd_hd_t __real_h264bsdAlloc(h264bsd_cfg_t *config) {
  ++calls;
  if (!config) return NULL;
  assert(config != &original);
  assert(config->dualTaskEnable == 0 && config->dualTaskCore == 1 && config->dualTaskPriority == 17);
  return &original;
}
int main(void) {
  assert(__wrap_h264bsdAlloc(&original) == &original && original.dualTaskEnable == 1);
  assert(__wrap_h264bsdAlloc(NULL) == NULL && calls == 2);
}
''')
    binary = tmp_path / 'serial'
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined',
                    str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
