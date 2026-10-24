/* Native GTK widgets using Waybar's public CFFI ABI version 2.
 * https://github.com/Alexays/Waybar/tree/0.15.0/resources/custom_modules/cffi_example
 */
#include <gtk/gtk.h>
#include <json-glib/json-glib.h>
#include <math.h>
#include <string.h>

typedef struct WaybarModule WaybarModule;
typedef struct {
  WaybarModule *obj;
  const char *waybar_version;
  GtkContainer *(*get_root_widget)(WaybarModule *);
  void (*queue_update)(WaybarModule *);
} InitInfo;
typedef struct { const char *key; const char *value; } ConfigEntry;
const size_t wbcffi_version = 2;

#define SAMPLES 100
#define SERIES 5
#define ITEMS 8

typedef struct {
  GtkWidget *box, *label, *value, *area;
  double history[SERIES][SAMPLES];
  GdkRGBA colors[SERIES];
  guint count, series;
  gint64 sequence;
  double maximum;
  gboolean autoscale;
} Graph;
typedef struct {
  GtkWidget *box, *image, *label;
  char *icon, *command;
} Item;
typedef struct {
  gint refs;
  gboolean dead, monitors, status;
  GtkWidget *box, *root, *clock, *calendar;
  Graph graph[3];
  Item item[ITEMS];
  char *command;
  GSubprocess *process;
  GDataInputStream *stream;
  GCancellable *cancel;
  guint restart, clock_timer;
} Module;

static gboolean update_clock(gpointer data) {
  Module *m = data;
  GDateTime *now = g_date_time_new_now_local();
  char *month = g_date_time_format(now, "%b");
  char *time = g_date_time_format(now, "%H:%M");
  char *label = g_strdup_printf("%s %d %s", month, g_date_time_get_day_of_month(now), time);
  gtk_label_set_text(GTK_LABEL(m->clock), label);
  g_free(label);
  g_free(month);
  g_free(time);
  g_date_time_unref(now);
  return G_SOURCE_CONTINUE;
}

static gboolean clock_click(GtkWidget *widget, GdkEventButton *event, gpointer data) {
  (void)widget;
  Module *m = data;
  if (event->button != 1) return FALSE;
  if (gtk_widget_get_visible(m->calendar)) gtk_popover_popdown(GTK_POPOVER(m->calendar));
  else gtk_popover_popup(GTK_POPOVER(m->calendar));
  return TRUE;
}

static const char *text(JsonObject *o, const char *key) {
  if (!json_object_has_member(o, key)) return "";
  JsonNode *node = json_object_get_member(o, key);
  return JSON_NODE_HOLDS_VALUE(node) && json_node_get_value_type(node) == G_TYPE_STRING
      ? json_node_get_string(node) : "";
}

static void css(GtkWidget *widget, const char *name) {
  gtk_style_context_add_class(gtk_widget_get_style_context(widget), name);
}

static gboolean draw_graph(GtkWidget *widget, cairo_t *cr, gpointer data) {
  Graph *g = data;
  if (!g->series) return FALSE;
  const double width = gtk_widget_get_allocated_width(widget);
  const double height = gtk_widget_get_allocated_height(widget);
  double max = g->maximum;
  if (g->autoscale) {
    max = 1;
    for (guint j = 0; j < g->count; j++)
      max = MAX(max, g->history[g->series - 1][j]);
    max = pow(2, ceil(log2(max)));
  }
  if (max <= 0 || g->count < 2) return FALSE;
  cairo_rectangle(cr, 0, 0, width, height);
  cairo_clip(cr);
  for (gint i = (gint)g->series - 1; i >= 0; i--) {
    cairo_move_to(cr, width, height);
    double x = width - 0.25;
    cairo_line_to(cr, x, height * (1 - g->history[i][g->count - 1] / max));
    x -= 0.5;
    for (gint j = (gint)g->count - 1; j >= 0; j--) {
      double y = height * (1 - g->history[i][j] / max);
      cairo_line_to(cr, x, y);
      x -= 0.5;
      cairo_line_to(cr, x, y);
      x -= 0.5;
    }
    cairo_line_to(cr, x + 0.75, height);
    cairo_close_path(cr);
    gdk_cairo_set_source_rgba(cr, &g->colors[i]);
    cairo_fill(cr);
  }
  return FALSE;
}

static gboolean draw_activities(GtkWidget *widget, cairo_t *cr, gpointer data) {
  (void)data;
  double y = gtk_widget_get_allocated_height(widget) / 2.0;
  cairo_set_source_rgb(cr, 1, 1, 1);
  cairo_arc(cr, 6, y, 4, M_PI_2, 3 * M_PI_2);
  cairo_arc(cr, 24, y, 4, 3 * M_PI_2, M_PI_2);
  cairo_close_path(cr);
  cairo_fill(cr);
  cairo_arc(cr, 37, y, 4, 0, 2 * M_PI);
  cairo_fill(cr);
  return FALSE;
}

static void make_graph(Module *m, guint index, const char *name) {
  Graph *g = &m->graph[index];
  g->sequence = -1;
  g->maximum = 100;
  g->box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
  css(g->box, "gnome-monitor");
  g->label = gtk_label_new(name);
  gtk_label_set_angle(GTK_LABEL(g->label), 90);
  css(g->label, "monitor-name");
  gtk_widget_set_margin_end(g->label, 2);
  g->value = gtk_label_new("—");
  /* The current GNOME extension uses graph-only mode, with values in tooltips. */
  gtk_widget_set_no_show_all(g->value, TRUE);
  gtk_label_set_xalign(GTK_LABEL(g->value), 1);
  css(g->value, "monitor-value");
  g->area = gtk_drawing_area_new();
  gtk_widget_set_size_request(g->area, SAMPLES, 1);
  gtk_widget_set_valign(g->area, GTK_ALIGN_FILL);
  gtk_widget_set_margin_start(g->area, 2);
  gtk_widget_set_margin_end(g->area, 2);
  css(g->area, "monitor-graph");
  g_signal_connect(g->area, "draw", G_CALLBACK(draw_graph), g);
  gtk_box_pack_start(GTK_BOX(g->box), g->label, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(g->box), g->value, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(g->box), g->area, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(m->box), g->box, FALSE, FALSE, 0);
}

static gboolean item_click(GtkWidget *widget, GdkEventButton *event, gpointer data) {
  (void)widget;
  Item *item = data;
  if (event->button != 1 || !item->command || !*item->command) return FALSE;
  GError *error = NULL;
  g_spawn_command_line_async(item->command, &error);
  g_clear_error(&error);
  return TRUE;
}

static void update_items(Module *m, JsonArray *array) {
  guint count = MIN(json_array_get_length(array), ITEMS);
  for (guint i = 0; i < count; i++) {
    JsonObject *o = json_array_get_object_element(array, i);
    Item *item = &m->item[i];
    if (!item->box) {
      item->box = gtk_event_box_new();
      GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
      gtk_container_add(GTK_CONTAINER(item->box), row);
      css(item->box, "gnome-item");
      if (m->status) {
        gtk_widget_set_margin_start(item->box, 4);
        gtk_widget_set_margin_end(item->box, 4);
      }
      item->image = gtk_image_new();
      item->label = gtk_label_new("");
      css(item->image, "gnome-icon");
      css(item->label, "gnome-text");
      gtk_box_pack_start(GTK_BOX(row), item->image, FALSE, FALSE, 0);
      gtk_box_pack_start(GTK_BOX(row), item->label, FALSE, FALSE, 0);
      gtk_box_pack_start(GTK_BOX(m->box), item->box, FALSE, FALSE, 0);
      g_signal_connect(item->box, "button-press-event", G_CALLBACK(item_click), item);
    }
    const char *icon = text(o, "icon");
    if (g_strcmp0(icon, item->icon) != 0) {
      g_free(item->icon);
      item->icon = g_strdup(icon);
      if (g_path_is_absolute(icon)) {
        GError *error = NULL;
        GdkPixbuf *pixbuf = gdk_pixbuf_new_from_file_at_scale(icon, 16, 16, TRUE, &error);
        gtk_image_set_from_pixbuf(GTK_IMAGE(item->image), pixbuf);
        g_clear_object(&pixbuf);
        g_clear_error(&error);
      } else {
        gtk_image_set_from_icon_name(GTK_IMAGE(item->image), icon, GTK_ICON_SIZE_MENU);
        gtk_image_set_pixel_size(GTK_IMAGE(item->image), 16);
      }
    }
    gtk_label_set_text(GTK_LABEL(item->label), text(o, "text"));
    gtk_widget_set_margin_start(item->label, *icon && *text(o, "text") ? 6 : 0);
    gtk_widget_set_tooltip_text(item->box, text(o, "tooltip"));
    g_free(item->command);
    item->command = g_strdup(text(o, "command"));
    gtk_widget_show_all(item->box);
    gtk_widget_set_visible(item->image, *icon != '\0');
    gtk_widget_set_visible(item->label, *text(o, "text") != '\0');
  }
  for (guint i = count; i < ITEMS; i++)
    if (m->item[i].box) gtk_widget_hide(m->item[i].box);
}

static void update_graph(Graph *g, JsonObject *o) {
  gtk_label_set_markup(GTK_LABEL(g->value), text(o, "markup"));
  gtk_widget_set_tooltip_text(g->box, text(o, "tooltip"));
  gint64 sequence = json_object_get_int_member(o, "sequence");
  if (sequence == g->sequence) return;
  g->sequence = sequence;
  JsonArray *values = json_object_get_array_member(o, "values");
  JsonArray *colors = json_object_get_array_member(o, "colors");
  g->series = MIN(json_array_get_length(values), SERIES);
  if (!g->series) return;
  g->maximum = json_object_get_double_member(o, "maximum");
  g->autoscale = g->maximum <= 0;
  if (g->count == SAMPLES) {
    for (guint i = 0; i < SERIES; i++)
      memmove(g->history[i], g->history[i] + 1, (SAMPLES - 1) * sizeof(double));
    g->count--;
  }
  double total = 0;
  for (guint i = 0; i < g->series; i++) {
    double value = json_array_get_double_element(values, i);
    total += isfinite(value) ? MAX(0, value) : 0;
    g->history[i][g->count] = total;
    const char *color = i < json_array_get_length(colors)
        ? json_array_get_string_element(colors, i) : "white";
    gdk_rgba_parse(&g->colors[i], color);
  }
  g->count++;
  gtk_widget_queue_draw(g->area);
}

static void update_line(Module *m, const char *line) {
  JsonParser *parser = json_parser_new();
  if (json_parser_load_from_data(parser, line, -1, NULL)) {
    JsonNode *node = json_parser_get_root(parser);
    if (JSON_NODE_HOLDS_OBJECT(node)) {
      JsonObject *o = json_node_get_object(node);
      if (m->monitors && json_object_has_member(o, "monitors")) {
        JsonArray *graphs = json_object_get_array_member(o, "monitors");
        for (guint i = 0; i < MIN(3, json_array_get_length(graphs)); i++)
          update_graph(&m->graph[i], json_array_get_object_element(graphs, i));
      } else if (!m->monitors && json_object_has_member(o, "items")) {
        update_items(m, json_object_get_array_member(o, "items"));
      }
      gtk_widget_set_tooltip_text(m->box, text(o, "tooltip"));
    }
  }
  g_object_unref(parser);
}

static void unref_module(Module *m) {
  if (--m->refs != 0) return;
  g_clear_object(&m->stream);
  g_clear_object(&m->process);
  g_clear_object(&m->cancel);
  g_free(m->command);
  for (guint i = 0; i < ITEMS; i++) {
    g_free(m->item[i].icon);
    g_free(m->item[i].command);
  }
  g_free(m);
}

static void read_next(Module *m);
static gboolean start_process(gpointer data);

static void line_ready(GObject *source, GAsyncResult *result, gpointer data) {
  Module *m = data;
  gsize length = 0;
  GError *error = NULL;
  char *line = g_data_input_stream_read_line_finish(G_DATA_INPUT_STREAM(source), result, &length, &error);
  if (!m->dead) {
    if (line) {
      if (length < 65536) update_line(m, line);
      read_next(m);
    } else {
      gtk_widget_set_tooltip_text(m->box, "Panel data unavailable; retrying");
      m->restart = g_timeout_add_seconds(5, start_process, m);
    }
  }
  g_free(line);
  g_clear_error(&error);
  unref_module(m);
}

static void read_next(Module *m) {
  m->refs++;
  g_data_input_stream_read_line_async(m->stream, G_PRIORITY_DEFAULT, m->cancel, line_ready, m);
}

static gboolean start_process(gpointer data) {
  Module *m = data;
  m->restart = 0;
  g_clear_object(&m->stream);
  if (m->process) g_subprocess_force_exit(m->process);
  g_clear_object(&m->process);
  char **argv = NULL;
  GError *error = NULL;
  if (g_shell_parse_argv(m->command, NULL, &argv, &error))
    m->process = g_subprocess_newv((const char *const *)argv,
        G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_SILENCE, &error);
  g_strfreev(argv);
  g_clear_error(&error);
  if (m->process) {
    m->stream = g_data_input_stream_new(g_subprocess_get_stdout_pipe(m->process));
    read_next(m);
  } else {
    m->restart = g_timeout_add_seconds(5, start_process, m);
  }
  return G_SOURCE_REMOVE;
}

static char *config_string(const ConfigEntry *entries, size_t length, const char *key) {
  for (size_t i = 0; i < length; i++) {
    if (strcmp(entries[i].key, key) != 0) continue;
    JsonParser *parser = json_parser_new();
    char *value = NULL;
    if (json_parser_load_from_data(parser, entries[i].value, -1, NULL))
      value = g_strdup(json_node_get_string(json_parser_get_root(parser)));
    g_object_unref(parser);
    return value;
  }
  return NULL;
}

void *wbcffi_init(const InitInfo *info, const ConfigEntry *entries, size_t length) {
  Module *m = g_new0(Module, 1);
  m->refs = 1;
  m->cancel = g_cancellable_new();
  char *kind = config_string(entries, length, "kind");
  char *name = config_string(entries, length, "name");
  m->monitors = g_strcmp0(kind, "monitors") == 0;
  m->status = g_strcmp0(name, "gnome-status") == 0;
  m->box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, m->monitors || m->status ? 4 : 0);
  if (g_strcmp0(name, "gnome-disk") != 0) {
    gtk_widget_set_margin_start(m->box, 15);
    gtk_widget_set_margin_end(m->box, 15);
    if (!m->monitors) {
      gtk_widget_set_margin_top(m->box, 3);
      gtk_widget_set_margin_bottom(m->box, 3);
    }
  }
  GtkContainer *root = info->get_root_widget(info->obj);
  m->root = GTK_WIDGET(root);
  if (name) gtk_widget_set_name(GTK_WIDGET(root), name);
  css(GTK_WIDGET(root), "gnome-panel-module");
  gtk_container_add(root, m->box);
  if (m->monitors) {
    make_graph(m, 0, "cpu");
    make_graph(m, 1, "mem");
    make_graph(m, 2, "net");
  } else if (g_strcmp0(kind, "clock") == 0) {
    m->clock = gtk_label_new("");
    gtk_container_add(GTK_CONTAINER(m->box), m->clock);
    m->calendar = gtk_popover_new(m->root);
    /* A layer-shell panel is only bar-height; let the calendar extend below it. */
    gtk_popover_set_constrain_to(GTK_POPOVER(m->calendar), GTK_POPOVER_CONSTRAINT_NONE);
    gtk_popover_set_position(GTK_POPOVER(m->calendar), GTK_POS_BOTTOM);
    css(m->calendar, "gnome-calendar");
    GtkWidget *calendar = gtk_calendar_new();
    gtk_container_add(GTK_CONTAINER(m->calendar), calendar);
    gtk_widget_show(calendar);
    g_signal_connect(m->root, "button-press-event", G_CALLBACK(clock_click), m);
    update_clock(m);
    m->clock_timer = g_timeout_add_seconds(1, update_clock, m);
  } else if (g_strcmp0(kind, "activities") == 0) {
    GtkWidget *area = gtk_drawing_area_new();
    gtk_widget_set_size_request(area, 42, 20);
    g_signal_connect(area, "draw", G_CALLBACK(draw_activities), NULL);
    gtk_container_add(GTK_CONTAINER(m->box), area);
  }
  m->command = config_string(entries, length, "exec");
  gtk_widget_show_all(m->box);
  if (m->command) start_process(m);
  g_free(name);
  g_free(kind);
  return m;
}

void wbcffi_deinit(void *instance) {
  Module *m = instance;
  m->dead = TRUE;
  if (m->clock_timer) g_source_remove(m->clock_timer);
  if (m->calendar) gtk_widget_destroy(m->calendar);
  g_signal_handlers_disconnect_by_data(m->root, m);
  if (m->restart) g_source_remove(m->restart);
  g_cancellable_cancel(m->cancel);
  if (m->process) g_subprocess_force_exit(m->process);
  for (guint i = 0; i < 3; i++)
    if (m->graph[i].area) g_signal_handlers_disconnect_by_data(m->graph[i].area, &m->graph[i]);
  for (guint i = 0; i < ITEMS; i++)
    if (m->item[i].box) g_signal_handlers_disconnect_by_data(m->item[i].box, &m->item[i]);
  unref_module(m);
}

void wbcffi_update(void *instance) { (void)instance; }
void wbcffi_refresh(void *instance, int signal) { (void)instance; (void)signal; }
void wbcffi_doaction(void *instance, const char *action) { (void)instance; (void)action; }
