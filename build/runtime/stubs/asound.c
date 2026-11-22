/* Stub libasound.so.2 (ALSA) for the rut360gw embedded runtime.
 * chan_quectel imports it for its UAC mode (USB sound card), never used on the RUT360:
 * voice goes through the serial port (AT+QPCMV), "uac = off" is hard-coded in the
 * quectel.conf template, and the router has no USB port. Every open returns -ENODEV (-19). */
#include <stddef.h>
const char *snd_asoundlib_version(void) { return "0.0.0-rut360gw"; }
const char *snd_strerror(int e) { (void)e; return "ALSA not available (rut360gw stub)"; }
const char *snd_pcm_state_name(int s) { (void)s; return "ABSENT"; }
size_t snd_pcm_hw_params_sizeof(void) { return 64; }
size_t snd_pcm_sw_params_sizeof(void) { return 64; }
size_t snd_pcm_status_sizeof(void) { return 64; }
int snd_pcm_state(void *p) { (void)p; return 8; }  /* SND_PCM_STATE_DISCONNECTED */
int snd_pcm_status_get_state(void *p) { (void)p; return 8; }
long snd_pcm_avail_update(void *p) { (void)p; return -19; }
long snd_pcm_mmap_readi(void *p, void *b, unsigned long n) { (void)p; (void)b; (void)n; return -19; }
long snd_pcm_mmap_writei(void *p, const void *b, unsigned long n) { (void)p; (void)b; (void)n; return -19; }
long snd_pcm_mmap_writen(void *p, void **b, unsigned long n) { (void)p; (void)b; (void)n; return -19; }
unsigned long snd_pcm_status_get_avail(void *p) { (void)p; return 0; }
long snd_pcm_status_get_delay(void *p) { (void)p; return 0; }
int snd_pcm_close(void) { return -19; }
int snd_pcm_get_params(void) { return -19; }
int snd_pcm_hw_params(void) { return -19; }
int snd_pcm_hw_params_any(void) { return -19; }
int snd_pcm_hw_params_current(void) { return -19; }
int snd_pcm_hw_params_get_buffer_size(void) { return -19; }
int snd_pcm_hw_params_get_channels(void) { return -19; }
int snd_pcm_hw_params_get_period_size(void) { return -19; }
int snd_pcm_hw_params_get_rate(void) { return -19; }
int snd_pcm_hw_params_set_access(void) { return -19; }
int snd_pcm_hw_params_set_buffer_size_near(void) { return -19; }
int snd_pcm_hw_params_set_channels_near(void) { return -19; }
int snd_pcm_hw_params_set_format(void) { return -19; }
int snd_pcm_hw_params_set_period_size_near(void) { return -19; }
int snd_pcm_hw_params_set_rate(void) { return -19; }
int snd_pcm_link(void) { return -19; }
int snd_pcm_open(void) { return -19; }
int snd_pcm_poll_descriptors(void) { return -19; }
int snd_pcm_poll_descriptors_count(void) { return -19; }
int snd_pcm_prepare(void) { return -19; }
int snd_pcm_status(void) { return -19; }
int snd_pcm_sw_params(void) { return -19; }
int snd_pcm_sw_params_current(void) { return -19; }
int snd_pcm_sw_params_get_boundary(void) { return -19; }
int snd_pcm_sw_params_set_silence_size(void) { return -19; }
int snd_pcm_sw_params_set_silence_threshold(void) { return -19; }
int snd_pcm_sw_params_set_start_threshold(void) { return -19; }
int snd_pcm_sw_params_set_stop_threshold(void) { return -19; }
int snd_pcm_unlink(void) { return -19; }
