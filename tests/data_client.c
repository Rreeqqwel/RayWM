#define _GNU_SOURCE
#include <wayland-client.h>
#include "xdg-shell-client.h"
#include "text-input-client.h"
#include "input-method-client.h"
#include "virtual-keyboard-client.h"
#include <sys/mman.h>
#include <unistd.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_seat *seat;
static struct xdg_wm_base *shell;
static struct wl_surface *surface;
static struct xdg_surface *xs;
static struct wl_data_device_manager *data_manager;
static struct wl_data_device *device;
static struct wl_data_offer *offer;
static struct zwp_text_input_manager_v3 *text_manager;
static struct zwp_input_method_manager_v2 *method_manager;
static struct zwp_text_input_v3 *text;
static struct zwp_input_method_v2 *method;
static struct zwp_input_method_keyboard_grab_v2 *grab;
static struct zwp_virtual_keyboard_manager_v1 *keyboard_manager;
static struct zwp_virtual_keyboard_v1 *virtual_keyboard;
static struct wl_keyboard *text_keyboard;
static struct wl_surface *popup_surface;
static struct zwp_input_popup_surface_v2 *popup;
static int keymap_fd = -1;
static uint32_t keymap_size, fill = 0xff884422;
static const char *role;
static int width=200,height=150, active, method_serial, entered;
static struct wl_buffer *buffer(int w,int h) {
    int fd=memfd_create("raywm-client",MFD_CLOEXEC);if(fd<0) exit(2);
    size_t size=(size_t)w*h*4;if(ftruncate(fd,size)) exit(2);
    uint32_t *pixels=mmap(NULL,size,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);if(pixels==MAP_FAILED) exit(2);
    for(size_t i=0;i<size/4;i++)pixels[i]=fill;
    struct wl_shm_pool *pool=wl_shm_create_pool(shm,fd,size);
    struct wl_buffer *buf=wl_shm_pool_create_buffer(pool,0,w,h,w*4,WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);munmap(pixels,size);close(fd);return buf;
}
static void ping(void *d,struct xdg_wm_base *s,uint32_t serial){(void)d;xdg_wm_base_pong(s,serial);}
static const struct xdg_wm_base_listener shell_listener={.ping=ping};
static void configured(void*d,struct xdg_surface *s,uint32_t serial){(void)d;xdg_surface_ack_configure(s,serial);struct wl_buffer*b=buffer(width,height);wl_surface_attach(surface,b,0,0);wl_surface_damage_buffer(surface,0,0,width,height);wl_surface_commit(surface);wl_buffer_destroy(b);puts("data: mapped");}
static const struct xdg_surface_listener xs_listener={.configure=configured};
static void size(void*d,struct xdg_toplevel*t,int32_t w,int32_t h,struct wl_array*a){(void)d;(void)t;(void)a;if(w>0)width=w;if(h>0)height=h;}
static void close_window(void*d,struct xdg_toplevel*t){(void)d;(void)t;exit(0);}
static const struct xdg_toplevel_listener toplevel_listener={.configure=size,.close=close_window};
static void target(void*d,struct wl_data_source*s,const char*m){(void)d;(void)s;(void)m;}
static void send_data(void*d,struct wl_data_source*s,const char*m,int32_t fd){(void)d;(void)s;(void)m;const char bytes[]="raywm-drag-\xD0\xB4\xD0\xB0\xD0\xBD\xD0\xBD\xD1\x8B\xD0\xB5";write(fd,bytes,sizeof(bytes)-1);close(fd);puts("data: sent");}
static void cancelled(void*d,struct wl_data_source*s){(void)d;wl_data_source_destroy(s);puts("data: cancelled");}
static void drop_done(void*d,struct wl_data_source*s){(void)d;(void)s;puts("data: drop performed");}
static void finished(void*d,struct wl_data_source*s){(void)d;wl_data_source_destroy(s);puts("data: finished");}
static void source_action(void*d,struct wl_data_source*s,uint32_t a){(void)d;(void)s;(void)a;}
static const struct wl_data_source_listener source_listener={target,send_data,cancelled,drop_done,finished,source_action};
static void offer_mime(void*d,struct wl_data_offer*o,const char*m){(void)d;(void)o;printf("data: mime %s\n",m);}
static void offer_source_actions(void*d,struct wl_data_offer*o,uint32_t a){(void)d;(void)o;(void)a;}
static const struct wl_data_offer_listener offer_listener={offer_mime,offer_source_actions,offer_source_actions};
static void data_offer(void*d,struct wl_data_device*dev,struct wl_data_offer*o){(void)d;(void)dev;wl_data_offer_add_listener(o,&offer_listener,NULL);}
static void data_enter(void*d,struct wl_data_device*dev,uint32_t serial,struct wl_surface*s,wl_fixed_t x,wl_fixed_t y,struct wl_data_offer*o){(void)d;(void)dev;(void)s;(void)x;(void)y;offer=o;entered=1;if(o){wl_data_offer_accept(o,serial,"text/plain;charset=utf-8");wl_data_offer_set_actions(o,WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY,WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY);}puts("data: enter");}
static void data_leave(void*d,struct wl_data_device*dev){(void)d;(void)dev;entered=0;puts("data: leave");}
static void data_motion(void*d,struct wl_data_device*dev,uint32_t t,wl_fixed_t x,wl_fixed_t y){(void)d;(void)dev;(void)t;(void)x;(void)y;}
static void data_drop(void*d,struct wl_data_device*dev){(void)d;(void)dev;puts("data: drop");if(!offer)return;int fds[2];if(pipe2(fds,O_CLOEXEC))exit(2);wl_data_offer_receive(offer,"text/plain;charset=utf-8",fds[1]);close(fds[1]);wl_display_flush(display);struct pollfd p={fds[0],POLLIN,0};if(poll(&p,1,4000)>0){char bytes[128];ssize_t n=read(fds[0],bytes,sizeof(bytes));if(n>0)printf("data: received %.*s\n",(int)n,bytes);}close(fds[0]);wl_data_offer_finish(offer);wl_data_offer_destroy(offer);offer=NULL;}
static void selection(void*d,struct wl_data_device*dev,struct wl_data_offer*o){(void)d;(void)dev;if(o)wl_data_offer_destroy(o);}
static const struct wl_data_device_listener data_listener={data_offer,data_enter,data_leave,data_motion,data_drop,selection};
static void pointer_enter(void*d,struct wl_pointer*p,uint32_t serial,struct wl_surface*s,wl_fixed_t x,wl_fixed_t y){(void)d;(void)p;(void)s;(void)x;(void)y;if(getenv("RAYWM_TEST_BAD_DRAG")){struct wl_data_source*source=wl_data_device_manager_create_data_source(data_manager);wl_data_source_add_listener(source,&source_listener,NULL);wl_data_source_offer(source,"text/plain;charset=utf-8");wl_data_device_start_drag(device,source,surface,NULL,serial);puts("data: invalid drag sent");}}
static void pointer_button(void*d,struct wl_pointer*p,uint32_t serial,uint32_t t,uint32_t b,uint32_t state){(void)d;(void)p;(void)t;(void)b;if(state==WL_POINTER_BUTTON_STATE_PRESSED&&!strcmp(role,"source")){struct wl_data_source*source=wl_data_device_manager_create_data_source(data_manager);wl_data_source_add_listener(source,&source_listener,NULL);wl_data_source_offer(source,"text/plain;charset=utf-8");wl_data_source_set_actions(source,WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY);struct wl_surface*icon=wl_compositor_create_surface(compositor);wl_data_device_start_drag(device,source,surface,icon,serial);struct wl_buffer*buf=buffer(40,40);wl_surface_attach(icon,buf,0,0);wl_surface_commit(icon);wl_buffer_destroy(buf);puts("data: drag started");}}
static void pointer_leave(void*d,struct wl_pointer*p,uint32_t s,struct wl_surface*sf){(void)d;(void)p;(void)s;(void)sf;}
static void pointer_motion(void*d,struct wl_pointer*p,uint32_t t,wl_fixed_t x,wl_fixed_t y){(void)d;(void)p;(void)t;(void)x;(void)y;}
static void pointer_axis(void*d,struct wl_pointer*p,uint32_t t,uint32_t a,wl_fixed_t v){(void)d;(void)p;(void)t;(void)a;(void)v;}
static void pointer_frame(void*d,struct wl_pointer*p){(void)d;(void)p;}
static void pointer_axis_source(void*d,struct wl_pointer*p,uint32_t a){(void)d;(void)p;(void)a;}
static void pointer_axis_stop(void*d,struct wl_pointer*p,uint32_t t,uint32_t a){(void)d;(void)p;(void)t;(void)a;}
static void pointer_axis_discrete(void*d,struct wl_pointer*p,uint32_t a,int32_t v){(void)d;(void)p;(void)a;(void)v;}
static const struct wl_pointer_listener pointer_listener={.enter=pointer_enter,.leave=pointer_leave,.motion=pointer_motion,.button=pointer_button,.axis=pointer_axis,.frame=pointer_frame,.axis_source=pointer_axis_source,.axis_stop=pointer_axis_stop,.axis_discrete=pointer_axis_discrete};
static void keyboard_keymap(void*d,struct wl_keyboard*k,uint32_t format,int fd,uint32_t size){(void)d;(void)k;(void)format;(void)size;close(fd);}
static void keyboard_enter(void*d,struct wl_keyboard*k,uint32_t serial,struct wl_surface*s,struct wl_array*keys){(void)d;(void)k;(void)serial;(void)s;(void)keys;puts("text: keyboard enter");}
static void keyboard_leave(void*d,struct wl_keyboard*k,uint32_t serial,struct wl_surface*s){(void)d;(void)k;(void)serial;(void)s;}
static void keyboard_key(void*d,struct wl_keyboard*k,uint32_t serial,uint32_t time,uint32_t key,uint32_t state){(void)d;(void)k;(void)serial;(void)time;printf("text: key %u %u\n",key,state);}
static void keyboard_modifiers(void*d,struct wl_keyboard*k,uint32_t serial,uint32_t a,uint32_t b,uint32_t c,uint32_t e){(void)d;(void)k;(void)serial;(void)a;(void)b;(void)c;(void)e;}
static void keyboard_repeat(void*d,struct wl_keyboard*k,int32_t rate,int32_t delay){(void)d;(void)k;(void)rate;(void)delay;}
static const struct wl_keyboard_listener keyboard_listener={keyboard_keymap,keyboard_enter,keyboard_leave,keyboard_key,keyboard_modifiers,keyboard_repeat};
static void popup_rectangle(void*d,struct zwp_input_popup_surface_v2*p,int32_t x,int32_t y,int32_t w,int32_t h){(void)d;(void)p;printf("ime: rectangle %d %d %d %d\n",x,y,w,h);}
static const struct zwp_input_popup_surface_v2_listener popup_listener={popup_rectangle};
static int pointer_created, keyboard_created;
static void capabilities(void*d,struct wl_seat*s,uint32_t caps){(void)d;if((caps&WL_SEAT_CAPABILITY_POINTER)&&!pointer_created&&surface){struct wl_pointer*p=wl_seat_get_pointer(s);wl_pointer_add_listener(p,&pointer_listener,NULL);pointer_created=1;}if((caps&WL_SEAT_CAPABILITY_KEYBOARD)&&!keyboard_created&&surface){text_keyboard=wl_seat_get_keyboard(s);wl_keyboard_add_listener(text_keyboard,&keyboard_listener,NULL);keyboard_created=1;}if(!(caps&WL_SEAT_CAPABILITY_KEYBOARD)&&keyboard_created){wl_keyboard_release(text_keyboard);text_keyboard=NULL;keyboard_created=0;}}
static void seat_name(void*d,struct wl_seat*s,const char*n){(void)d;(void)s;(void)n;}
static const struct wl_seat_listener seat_listener={capabilities,seat_name};
static void text_enter(void*d,struct zwp_text_input_v3*t,struct wl_surface*s){(void)d;(void)s;zwp_text_input_v3_enable(t);zwp_text_input_v3_set_surrounding_text(t,"hello",5,5);zwp_text_input_v3_set_content_type(t,0,0);zwp_text_input_v3_set_cursor_rectangle(t,20,30,2,18);zwp_text_input_v3_commit(t);puts("text: enter");}
static void text_leave(void*d,struct zwp_text_input_v3*t,struct wl_surface*s){(void)d;(void)t;(void)s;puts("text: leave");}
static void preedit(void*d,struct zwp_text_input_v3*t,const char*s,int32_t a,int32_t b){(void)d;(void)t;(void)a;(void)b;printf("text: preedit %s\n",s?s:"");}
static void commit_text(void*d,struct zwp_text_input_v3*t,const char*s){(void)d;(void)t;printf("text: commit %s\n",s?s:"");}
static void delete_text(void*d,struct zwp_text_input_v3*t,uint32_t a,uint32_t b){(void)d;(void)t;printf("text: delete %u %u\n",a,b);}
static void text_done(void*d,struct zwp_text_input_v3*t,uint32_t serial){(void)d;(void)t;printf("text: done %u\n",serial);}
static const struct zwp_text_input_v3_listener text_listener={text_enter,text_leave,preedit,commit_text,delete_text,text_done};
static void grab_keymap(void*d,struct zwp_input_method_keyboard_grab_v2*g,uint32_t f,int fd,uint32_t size){(void)d;(void)g;(void)f;if(keymap_fd>=0)close(keymap_fd);keymap_fd=fd;keymap_size=size;puts("ime: keymap");}
static void grab_key(void*d,struct zwp_input_method_keyboard_grab_v2*g,uint32_t serial,uint32_t time,uint32_t key,uint32_t state){(void)d;(void)g;(void)serial;(void)time;printf("ime: key %u %u\n",key,state);}
static void grab_modifiers(void*d,struct zwp_input_method_keyboard_grab_v2*g,uint32_t a,uint32_t b,uint32_t c,uint32_t e,uint32_t f){(void)d;(void)g;(void)a;(void)b;(void)c;(void)e;(void)f;}
static void grab_repeat(void*d,struct zwp_input_method_keyboard_grab_v2*g,int32_t rate,int32_t delay){(void)d;(void)g;(void)rate;(void)delay;}
static const struct zwp_input_method_keyboard_grab_v2_listener grab_listener={grab_keymap,grab_key,grab_modifiers,grab_repeat};
static void method_activate(void*d,struct zwp_input_method_v2*m){(void)d;(void)m;active=1;puts("ime: activate");}
static void method_deactivate(void*d,struct zwp_input_method_v2*m){(void)d;(void)m;active=0;puts("ime: deactivate");}
static void surrounding(void*d,struct zwp_input_method_v2*m,const char*s,uint32_t a,uint32_t b){(void)d;(void)m;(void)a;(void)b;printf("ime: surrounding %s\n",s);}
static void cause(void*d,struct zwp_input_method_v2*m,uint32_t a){(void)d;(void)m;(void)a;}
static void content(void*d,struct zwp_input_method_v2*m,uint32_t a,uint32_t b){(void)d;(void)m;(void)a;(void)b;}
static void method_done(void*d,struct zwp_input_method_v2*m){(void)d;(void)m;method_serial++;puts("ime: done");}
static void unavailable(void*d,struct zwp_input_method_v2*m){(void)d;(void)m;puts("ime: unavailable");exit(0);}
static const struct zwp_input_method_v2_listener method_listener={method_activate,method_deactivate,surrounding,cause,content,method_done,unavailable};
static void global(void*d,struct wl_registry*r,uint32_t name,const char*interface,uint32_t version){(void)d;(void)version;
    if(!strcmp(interface,"wl_compositor"))compositor=wl_registry_bind(r,name,&wl_compositor_interface,4);
    else if(!strcmp(interface,"wl_shm"))shm=wl_registry_bind(r,name,&wl_shm_interface,1);
    else if(!strcmp(interface,"wl_seat")){seat=wl_registry_bind(r,name,&wl_seat_interface,7);wl_seat_add_listener(seat,&seat_listener,NULL);}
    else if(!strcmp(interface,"xdg_wm_base")){shell=wl_registry_bind(r,name,&xdg_wm_base_interface,1);xdg_wm_base_add_listener(shell,&shell_listener,NULL);}
    else if(!strcmp(interface,"wl_data_device_manager"))data_manager=wl_registry_bind(r,name,&wl_data_device_manager_interface,3);
    else if(!strcmp(interface,"zwp_text_input_manager_v3"))text_manager=wl_registry_bind(r,name,&zwp_text_input_manager_v3_interface,1);
    else if(!strcmp(interface,"zwp_input_method_manager_v2"))method_manager=wl_registry_bind(r,name,&zwp_input_method_manager_v2_interface,1);
    else if(!strcmp(interface,"zwp_virtual_keyboard_manager_v1"))keyboard_manager=wl_registry_bind(r,name,&zwp_virtual_keyboard_manager_v1_interface,1);
}
static void removed(void*d,struct wl_registry*r,uint32_t n){(void)d;(void)r;(void)n;}
static const struct wl_registry_listener registry_listener={global,removed};
int main(int argc,char**argv){
    if(argc<2)return 2;role=argv[1];setvbuf(stdout,NULL,_IONBF,0);display=wl_display_connect(NULL);if(!display)return 2;
    struct wl_registry*r=wl_display_get_registry(display);wl_registry_add_listener(r,&registry_listener,NULL);wl_display_roundtrip(display);
    if(!seat||!compositor||!shm||!shell||!data_manager)return 2;
    if(!strcmp(role,"ime")) {if(!method_manager)return 2;method=zwp_input_method_manager_v2_get_input_method(method_manager,seat);zwp_input_method_v2_add_listener(method,&method_listener,NULL);}
    else {surface=wl_compositor_create_surface(compositor);xs=xdg_wm_base_get_xdg_surface(shell,surface);xdg_surface_add_listener(xs,&xs_listener,NULL);struct xdg_toplevel*t=xdg_surface_get_toplevel(xs);xdg_toplevel_add_listener(t,&toplevel_listener,NULL);xdg_toplevel_set_app_id(t,role);xdg_toplevel_set_title(t,role);device=wl_data_device_manager_get_data_device(data_manager,seat);wl_data_device_add_listener(device,&data_listener,NULL);if(!strcmp(role,"text")){if(!text_manager)return 2;text=zwp_text_input_manager_v3_get_text_input(text_manager,seat);zwp_text_input_v3_add_listener(text,&text_listener,NULL);}wl_surface_commit(surface);}
    puts("data: ready");
    while(1){if(wl_display_dispatch_pending(display)<0)break;wl_display_flush(display);
        if(argc>2){FILE*f=fopen(argv[2],"r");if(f){char cmd[64]={0};fgets(cmd,sizeof(cmd),f);fclose(f);unlink(argv[2]);if(method){if(!strncmp(cmd,"commit",6)){zwp_input_method_v2_set_preedit_string(method,"composing",1,4);zwp_input_method_v2_commit_string(method,"composed");zwp_input_method_v2_delete_surrounding_text(method,1,0);zwp_input_method_v2_commit(method,method_serial);puts("ime: sent");}else if(!strncmp(cmd,"grab",4)){grab=zwp_input_method_v2_grab_keyboard(method);zwp_input_method_keyboard_grab_v2_add_listener(grab,&grab_listener,NULL);
            }else if(!strncmp(cmd,"reinject",8)) {
                if(!virtual_keyboard)exit(2);
                zwp_virtual_keyboard_v1_key(virtual_keyboard,0,36,WL_KEYBOARD_KEY_STATE_PRESSED);
                zwp_virtual_keyboard_v1_key(virtual_keyboard,1,36,WL_KEYBOARD_KEY_STATE_RELEASED);
                puts("ime: reinjected");
            }else if(!strncmp(cmd,"virtual",7)) {
                if(keymap_fd<0||!keyboard_manager)exit(2);
                if(!virtual_keyboard)virtual_keyboard=zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(keyboard_manager,seat);
                zwp_virtual_keyboard_v1_keymap(virtual_keyboard,1,keymap_fd,keymap_size);
            }else if(!strncmp(cmd,"popup",5)&&!popup) {
                popup_surface=wl_compositor_create_surface(compositor);
                popup=zwp_input_method_v2_get_input_popup_surface(method,popup_surface);
                zwp_input_popup_surface_v2_add_listener(popup,&popup_listener,NULL);
                fill=0xffff00ff;struct wl_buffer*b=buffer(80,40);fill=0xff884422;
                wl_surface_attach(popup_surface,b,0,0);wl_surface_commit(popup_surface);wl_buffer_destroy(b);
                puts("ime: popup");
            }else if(!strncmp(cmd,"unpopup",7)&&popup) {
                zwp_input_popup_surface_v2_destroy(popup);wl_surface_destroy(popup_surface);popup=NULL;
            }}wl_display_flush(display);}}
        struct pollfd p={wl_display_get_fd(display),POLLIN,0};if(poll(&p,1,20)>0&&wl_display_dispatch(display)<0)break;
    }return 0;
}
