
#include <gtk/gtk.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void write_text(const char *path, const char *text) {
    if (!path) return;
    FILE *file = fopen(path, "w");
    if (!file) return;
    fputs(text ? text : "", file);
    fclose(file);
}

static gboolean on_drop(GtkDropTarget *target, const GValue *value, double x, double y, gpointer data) {
    (void) target; (void) x; (void) y;
    (void) data;
    write_text(getenv("DROP_FILE"), g_value_get_string(value));
    return TRUE;
}

static void on_right_click(GtkGestureClick *gesture, int n_press, double x, double y, gpointer data) {
    (void) gesture; (void) n_press; (void) x; (void) y;
    GtkWidget *window = data;
    GtkWidget *popover = gtk_popover_new();
    GtkWidget *label = gtk_label_new("CTX-GTK");
    gtk_popover_set_child(GTK_POPOVER(popover), label);
    gtk_widget_set_parent(popover, window);
    gtk_popover_popup(GTK_POPOVER(popover));
}

static void on_drag_begin(GtkDragSource *source, GdkDrag *drag, gpointer data) {
    (void) source; (void) drag; (void) data;
    fprintf(stderr, "gtk drag-begin\n"); fflush(stderr);
}
static void on_drag_end(GtkDragSource *source, GdkDrag *drag, gboolean delete_data, gpointer data) {
    (void) source; (void) drag; (void) delete_data; (void) data;
    fprintf(stderr, "gtk drag-end\n"); fflush(stderr);
}
static gboolean on_drag_failed(GtkDragSource *source, GdkDrag *drag, GdkDragCancelReason reason, gpointer data) {
    (void) source; (void) drag; (void) data;
    fprintf(stderr, "gtk drag-failed %d\n", (int) reason); fflush(stderr);
    return FALSE;
}

static void activate(GtkApplication *app, gpointer data) {
    (void) data;
    const char *role = getenv("PROBE_ROLE");
    GtkWidget *window = gtk_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(window), "RayWM GTK DnD probe");
    gtk_window_set_default_size(GTK_WINDOW(window), 320, 200);
    gtk_window_set_decorated(GTK_WINDOW(window), FALSE);
    fprintf(stderr, "gtk backend=%s version=%u.%u.%u\n",
            G_OBJECT_TYPE_NAME(gtk_widget_get_display(window)),
            gtk_get_major_version(), gtk_get_minor_version(), gtk_get_micro_version());
    if (role && strcmp(role, "primary") == 0) {
        GtkWidget *text = gtk_text_view_new();
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(text)), "primary-gtk", -1);
        gtk_window_set_child(GTK_WINDOW(window), text);
    } else if (role && strcmp(role, "source") == 0) {
        GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
        GtkWidget *label = gtk_label_new("DRAG-GTK");
        gtk_widget_set_hexpand(label, FALSE);
        gtk_widget_set_vexpand(label, FALSE);
        gtk_widget_set_halign(label, GTK_ALIGN_START);
        gtk_widget_set_valign(label, GTK_ALIGN_START);
        gtk_widget_set_size_request(label, 200, 60);
        GtkDragSource *source = gtk_drag_source_new();
        GdkContentProvider *provider = gdk_content_provider_new_typed(G_TYPE_STRING, "gtk-to-qt");
        gtk_drag_source_set_content(source, provider);
        gtk_drag_source_set_actions(source, GDK_ACTION_COPY);
        g_signal_connect(source, "drag-begin", G_CALLBACK(on_drag_begin), NULL);
        g_signal_connect(source, "drag-end", G_CALLBACK(on_drag_end), NULL);
        g_signal_connect(source, "drag-failed", G_CALLBACK(on_drag_failed), NULL);
        gtk_widget_add_controller(label, GTK_EVENT_CONTROLLER(source));
        g_object_unref(provider);
        gtk_box_append(GTK_BOX(box), label);
        gtk_window_set_child(GTK_WINDOW(window), box);
        gtk_widget_set_can_focus(label, TRUE);
        gtk_widget_grab_focus(label);
    } else {
        GtkDropTarget *drop = gtk_drop_target_new(G_TYPE_STRING, GDK_ACTION_COPY);
        g_signal_connect(drop, "drop", G_CALLBACK(on_drop), NULL);
        gtk_widget_add_controller(window, GTK_EVENT_CONTROLLER(drop));
        GtkWidget *label = gtk_label_new("DROP-GTK");
        gtk_window_set_child(GTK_WINDOW(window), label);
    }
    GtkGesture *gesture = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(gesture), 3);
    g_signal_connect(gesture, "pressed", G_CALLBACK(on_right_click), window);
    gtk_widget_add_controller(window, GTK_EVENT_CONTROLLER(gesture));
    gtk_window_present(GTK_WINDOW(window));
}

int main(int argc, char **argv) {
    GtkApplication *app = gtk_application_new("org.raywm.GtkDndProbe", G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
    int status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return status;
}
