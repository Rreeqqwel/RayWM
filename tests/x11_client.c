/* Private XCB integration client; connects only to the test DISPLAY. */
#include <xcb/xcb.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <poll.h>

static xcb_connection_t *c;
static xcb_screen_t *screen;
static xcb_window_t win, menu;
static xcb_atom_t clipboard, utf8, targets, property;
static xcb_atom_t atom(const char *name) {
    xcb_intern_atom_reply_t *r = xcb_intern_atom_reply(c, xcb_intern_atom(c, 0, strlen(name), name), NULL);
    if (!r) exit(2);
    xcb_atom_t result = r->atom; free(r); return result;
}
static void state(const char *a, const char *b, int on) {
    xcb_client_message_event_t e = {0};
    e.response_type = XCB_CLIENT_MESSAGE; e.format = 32;
    e.window = win; e.type = atom("_NET_WM_STATE");
    e.data.data32[0] = on;
    e.data.data32[1] = atom(a);
    e.data.data32[2] = b ? atom(b) : 0;
    e.data.data32[3] = 1;
    xcb_send_event(c, 0, screen->root, XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT | XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY, (char *)&e);
}
static void command(char *cmd) {
    if (!strncmp(cmd,"fullscreen",10)) state("_NET_WM_STATE_FULLSCREEN",NULL,cmd[11]=='1');
    else if (!strncmp(cmd,"maximize",8)) state("_NET_WM_STATE_MAXIMIZED_HORZ","_NET_WM_STATE_MAXIMIZED_VERT",cmd[9]=='1');
    else if (!strncmp(cmd,"resize",6)) {
        uint32_t values[4] = {300,200,350,220};
        xcb_configure_window(c,win,XCB_CONFIG_WINDOW_X|XCB_CONFIG_WINDOW_Y|XCB_CONFIG_WINDOW_WIDTH|XCB_CONFIG_WINDOW_HEIGHT,values);
    } else if (!strncmp(cmd,"minimize",8)) {
        xcb_client_message_event_t e={0}; e.response_type=XCB_CLIENT_MESSAGE;e.format=32;e.window=win;e.type=atom("WM_CHANGE_STATE");e.data.data32[0]=3;
        xcb_send_event(c,0,screen->root,XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT|XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY,(char *)&e);
    } else if (!strncmp(cmd,"menu",4)) {
        menu=xcb_generate_id(c);
        uint32_t values[]={0xff00ff,1,XCB_EVENT_MASK_BUTTON_PRESS|XCB_EVENT_MASK_FOCUS_CHANGE};
        xcb_create_window(c,XCB_COPY_FROM_PARENT,menu,screen->root,700,200,100,80,0,XCB_WINDOW_CLASS_INPUT_OUTPUT,screen->root_visual,
            XCB_CW_BACK_PIXEL|XCB_CW_OVERRIDE_REDIRECT|XCB_CW_EVENT_MASK,values);
        xcb_change_property(c,XCB_PROP_MODE_REPLACE,menu,atom("WM_TRANSIENT_FOR"),XCB_ATOM_WINDOW,32,1,&win);
        xcb_map_window(c,menu);
        puts("x11: menu mapped");
    } else if (!strncmp(cmd,"unmenu",6)) {
        if(menu) xcb_destroy_window(c,menu); menu=0;
    } else if (!strncmp(cmd,"copy",4)) {
        xcb_set_selection_owner(c,win,clipboard,XCB_CURRENT_TIME);
        puts("x11: clipboard owned");
    } else if (!strncmp(cmd,"paste",5)) xcb_convert_selection(c,win,clipboard,utf8,property,XCB_CURRENT_TIME);
    else if (!strncmp(cmd,"quit",4)) { xcb_unmap_window(c,win);xcb_flush(c);usleep(150000);xcb_destroy_window(c,win);xcb_flush(c);exit(0); }
    xcb_flush(c);
}
int main(int argc,char **argv) {
    setvbuf(stdout,NULL,_IONBF,0);
    int number=0;c=xcb_connect(NULL,&number);
    if(xcb_connection_has_error(c)) return 2;
    xcb_screen_iterator_t it=xcb_setup_roots_iterator(xcb_get_setup(c));
    while(number--) xcb_screen_next(&it);screen=it.data;
    win=xcb_generate_id(c);
    uint32_t values[]={0x2288cc,XCB_EVENT_MASK_STRUCTURE_NOTIFY|XCB_EVENT_MASK_FOCUS_CHANGE|XCB_EVENT_MASK_KEY_PRESS|XCB_EVENT_MASK_BUTTON_PRESS};
    xcb_create_window(c,XCB_COPY_FROM_PARENT,win,screen->root,100,100,200,150,0,XCB_WINDOW_CLASS_INPUT_OUTPUT,screen->root_visual,XCB_CW_BACK_PIXEL|XCB_CW_EVENT_MASK,values);
    const char klass[]="raywm-x11\0raywm-x11\0";
    xcb_change_property(c,XCB_PROP_MODE_REPLACE,win,XCB_ATOM_WM_CLASS,XCB_ATOM_STRING,8,sizeof(klass)-1,klass);
    xcb_change_property(c,XCB_PROP_MODE_REPLACE,win,XCB_ATOM_WM_NAME,XCB_ATOM_STRING,8,9,"RayWM X11");
    uint32_t pid=getpid();xcb_change_property(c,XCB_PROP_MODE_REPLACE,win,atom("_NET_WM_PID"),XCB_ATOM_CARDINAL,32,1,&pid);
    xcb_atom_t protocols[]={atom("WM_DELETE_WINDOW")};
    xcb_change_property(c,XCB_PROP_MODE_REPLACE,win,atom("WM_PROTOCOLS"),XCB_ATOM_ATOM,32,1,protocols);
    clipboard=atom("CLIPBOARD");utf8=atom("UTF8_STRING");targets=atom("TARGETS");property=atom("RAYWM_TEST_SELECTION");
    if(getenv("RAYWM_TEST_X11_FULLSCREEN")||getenv("RAYWM_TEST_X11_MAXIMIZED")) {
        /* wlroots' XWM only learns pre-map state through PropertyNotify,
         * which it selects after it sees CreateNotify; a property set
         * earlier is overwritten at map (wlroots 0.20 race). Real clients
         * can lose that race too; this test exercises RayWM's handling of
         * the state wlroots does report, so wait for the selection. */
        for(int i=0;i<200;i++) {
            xcb_get_window_attributes_reply_t *a=xcb_get_window_attributes_reply(c,xcb_get_window_attributes(c,win),NULL);
            int ready=a&&(a->all_event_masks&XCB_EVENT_MASK_PROPERTY_CHANGE);
            free(a);
            if(ready) break;
            usleep(10000);
        }
    }
    if(getenv("RAYWM_TEST_X11_FULLSCREEN")) {
        /* Like SDL and Wine games: the state is set before the first map. */
        xcb_atom_t fs=atom("_NET_WM_STATE_FULLSCREEN");
        xcb_change_property(c,XCB_PROP_MODE_REPLACE,win,atom("_NET_WM_STATE"),XCB_ATOM_ATOM,32,1,&fs);
    } else if(getenv("RAYWM_TEST_X11_MAXIMIZED")) {
        xcb_atom_t max[]={atom("_NET_WM_STATE_MAXIMIZED_HORZ"),atom("_NET_WM_STATE_MAXIMIZED_VERT")};
        xcb_change_property(c,XCB_PROP_MODE_REPLACE,win,atom("_NET_WM_STATE"),XCB_ATOM_ATOM,32,2,max);
    }
    xcb_map_window(c,win);xcb_flush(c);
    puts("x11: connected");
    while(!xcb_connection_has_error(c)) {
        if(argc>1) {
            FILE *f=fopen(argv[1],"r");
            if(f) {char cmd[64]={0};if(fgets(cmd,sizeof(cmd),f)) command(cmd);fclose(f);unlink(argv[1]);}
        }
        xcb_generic_event_t *ev;
        while((ev=xcb_poll_for_event(c))) {
            switch(ev->response_type&127) {
            case XCB_MAP_NOTIFY: puts("x11: mapped");break;
            case XCB_CONFIGURE_NOTIFY: {
                xcb_configure_notify_event_t *e=(void *)ev;
                if(e->window==win)printf("x11: geometry %d,%d %ux%u\n",e->x,e->y,e->width,e->height);break;
            }
            case XCB_FOCUS_IN: puts("x11: focus in");break;
            case XCB_FOCUS_OUT: puts("x11: focus out");break;
            case XCB_BUTTON_PRESS: printf("x11: button %u %s\n",((xcb_button_press_event_t *)ev)->detail,((xcb_button_press_event_t *)ev)->event==menu?"menu":"window");break;
            case XCB_KEY_PRESS: printf("x11: key %u\n",((xcb_key_press_event_t *)ev)->detail);break;
            case XCB_CLIENT_MESSAGE: if(((xcb_client_message_event_t *)ev)->data.data32[0]==protocols[0]) { puts("x11: closed");free(ev);command("quit");return 0; }break;
            case XCB_SELECTION_REQUEST: {
                xcb_selection_request_event_t *e=(void *)ev;
                xcb_selection_notify_event_t reply={0}; reply.response_type=XCB_SELECTION_NOTIFY;reply.requestor=e->requestor;reply.selection=e->selection;reply.target=e->target;reply.time=e->time;reply.property=XCB_ATOM_NONE;
                xcb_atom_t dest=e->property?e->property:e->target;
                if(e->target==targets) {xcb_atom_t supported[]={targets,utf8};xcb_change_property(c,XCB_PROP_MODE_REPLACE,e->requestor,dest,XCB_ATOM_ATOM,32,2,supported);reply.property=dest;}
                else if(e->target==utf8) {const char text[]="raywm-x11-clipboard";xcb_change_property(c,XCB_PROP_MODE_REPLACE,e->requestor,dest,utf8,8,sizeof(text)-1,text);reply.property=dest;}
                xcb_send_event(c,0,e->requestor,0,(char *)&reply);xcb_flush(c);break;
            }
            case XCB_SELECTION_NOTIFY: {
                xcb_selection_notify_event_t *e=(void *)ev;
                if(e->property) {xcb_get_property_reply_t *r=xcb_get_property_reply(c,xcb_get_property(c,1,win,e->property,XCB_GET_PROPERTY_TYPE_ANY,0,4096),NULL);if(r){printf("x11: pasted %.*s\n",xcb_get_property_value_length(r),(char *)xcb_get_property_value(r));free(r);}}
                break;
            }
            }
            free(ev);
        }
        struct pollfd fd={xcb_get_file_descriptor(c),POLLIN,0};poll(&fd,1,20);
    }
    puts("x11: disconnected");xcb_disconnect(c);return 0;
}
