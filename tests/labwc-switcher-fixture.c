/* Native Wayland test windows; never connects to the user's desktop. */
#include <gtk/gtk.h>
#include <gdk/gdkwayland.h>
#include <stdio.h>

static void active_changed(GObject *object, GParamSpec *property, gpointer data) {
  (void)property;
  (void)data;
  if (gtk_window_is_active(GTK_WINDOW(object))) {
    printf("%" G_GINT64_FORMAT " %s\n", g_get_monotonic_time(),
           gtk_window_get_title(GTK_WINDOW(object)));
    fflush(stdout);
  }
}

int main(int argc, char **argv) {
  if (argc != 3) return 2;
  g_set_prgname(argv[1]);
  gtk_init(NULL, NULL);
  GtkWidget *window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(GTK_WINDOW(window), argv[2]);
  gtk_window_set_default_size(GTK_WINDOW(window), 640, 420);
  gtk_container_add(GTK_CONTAINER(window), gtk_label_new(argv[2]));
  g_signal_connect(window, "notify::is-active", G_CALLBACK(active_changed), NULL);
  g_signal_connect(window, "destroy", G_CALLBACK(gtk_main_quit), NULL);
  gtk_widget_realize(window);
  gdk_wayland_window_set_application_id(gtk_widget_get_window(window), argv[1]);
  gtk_widget_show_all(window);
  gtk_main();
  return 0;
}
