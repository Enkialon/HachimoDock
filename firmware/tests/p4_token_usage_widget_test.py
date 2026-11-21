"""Run the firmware formatter and Token widget update against an in-memory view."""
from pathlib import Path
import subprocess

from p4_render_trace_test import function


def test_token_snapshot_tracks_validity_source_and_empty_reset(tmp_path):
    main = Path(__file__).resolve().parents[1] / "main"
    code = (main / "pet_p4_miniapp.c").read_text()
    source = tmp_path / "token.c"
    source.write_text(r'''
#include <assert.h>
#include <stdio.h>
#include <stdbool.h>
#include <string.h>
#include "pet_p4_stats.h"
typedef struct {bool active; const char *widget_id;} runtime_t;
static runtime_t g_runtime={true,"other"};
static bool locked;
static int refreshes, assignments;
static const char *keys[]={"agent_label","total_display","input_display","output_display",
                           "cache_display","headline_text","breakdown_text"};
static char values[7][96];
static void miniapp_runtime_lock(void) {assert(!locked); locked=true;}
static void miniapp_runtime_unlock(void) {assert(locked); locked=false;}
static void refresh_view(runtime_t *r) {assert(locked && r==&g_runtime);refreshes++;}
static bool set_string_var(runtime_t *r,const char *key,const char *value) {
  assert(locked && r==&g_runtime);assignments++;
  for(int i=0;i<7;i++) if(!strcmp(keys[i],key)) {
    if(!strcmp(values[i],value))return false;
    assert(strlen(value)<sizeof(values[i]));strcpy(values[i],value);return true;
  }
  assert(0);return false;
}
''' + function(code, "format_compact_u64") + "\n" + function(code, "pet_p4_miniapp_sync_stats") + r'''
int main(void){
  pet_p4_stats_model_t stats={.source="codex",.valid=PET_P4_STATS_HAS_TOTAL_TOKENS|PET_P4_STATS_HAS_INPUT_TOKENS,.total_tokens=1500};
  assert(!pet_p4_miniapp_sync_stats(&stats) && !assignments && !locked);
  g_runtime.widget_id="token-usage";g_runtime.active=false;
  assert(!pet_p4_miniapp_sync_stats(&stats) && !assignments && !locked);
  g_runtime.active=true;
  assert(pet_p4_miniapp_sync_stats(&stats) && refreshes==1);
  assert(!strcmp(values[0],"ChatGPT (Codex)") && !strcmp(values[1],"1.5K"));
  assert(!strcmp(values[2],"0") && !strcmp(values[3],"-") && !strcmp(values[5],"已上报用量"));
  assert(!pet_p4_miniapp_sync_stats(&stats) && refreshes==1);
  stats=(pet_p4_stats_model_t){.source="claude",.valid=PET_P4_STATS_HAS_COST};
  assert(pet_p4_miniapp_sync_stats(&stats) && refreshes==2 && !strcmp(values[0],"Claude"));
  assert(!strcmp(values[1],"-") && !strcmp(values[2],"-") && !strcmp(values[5],"等待用量统计"));
  stats=(pet_p4_stats_model_t){0};
  assert(pet_p4_miniapp_sync_stats(&stats) && refreshes==3 && !strcmp(values[0],"当前 Agent"));
  assert(!pet_p4_miniapp_sync_stats(&stats) && refreshes==3 && !locked);
}
''')
    binary = tmp_path / "token"
    subprocess.run(["cc", "-std=c11", "-Wall", "-Werror", "-I", str(main), str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
