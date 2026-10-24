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
  GtkWidget *calendar_month, *calendar_weekday, *calendar_date, *calendar_days[42];
  GDateTime *calendar_selected;
  Graph graph[3];
  Item item[ITEMS];
  char *command;
  GSubprocess *process;
  GDataInputStream *stream;
  GCancellable *cancel;
  guint restart, clock_timer;
  GDBusProxy *power;
  GtkWidget *power_menu, *power_label, *power_icon, *power_message, *power_buttons[3];
  gboolean power_pending;
  GtkWidget *bluetooth_button, *bluetooth_label, *bluetooth_message;
  GtkWidget *network_icon, *network_label;
  char *bluetooth_command, *bluetooth_settings_command, *network_settings_command;
  gboolean bluetooth_powered, bluetooth_busy;
  guint bluetooth_timer;
} Module;

static void unref_module(Module *m);
static void css(GtkWidget *widget, const char *name);
static gboolean bluetooth_refresh(gpointer data);

static void bluetooth_ready(GObject *source, GAsyncResult *result, gpointer data) {
  Module *m = data;
  GError *error = NULL;
  char *output = NULL, *errors = NULL;
  gboolean ok = g_subprocess_communicate_utf8_finish(G_SUBPROCESS(source), result, &output, &errors, &error);
  if (!m->dead) {
    m->bluetooth_busy = FALSE;
    gboolean available = ok && g_subprocess_get_successful(G_SUBPROCESS(source)) &&
        output && strstr(output, "Powered:");
    m->bluetooth_powered = available && strstr(output, "Powered: yes");
    gtk_label_set_text(GTK_LABEL(m->bluetooth_label), m->bluetooth_powered ? "On" : "Off");
    GtkStyleContext *style = gtk_widget_get_style_context(m->bluetooth_button);
    if (m->bluetooth_powered) gtk_style_context_add_class(style, "quick-active");
    else gtk_style_context_remove_class(style, "quick-active");
    gtk_widget_set_sensitive(m->bluetooth_button, available);
    gtk_label_set_text(GTK_LABEL(m->bluetooth_message), available ? "" :
        error ? error->message : "Bluetooth unavailable");
  }
  g_clear_error(&error);
  g_free(output);
  g_free(errors);
  unref_module(m);
}

static void bluetooth_run(Module *m, GAsyncReadyCallback callback, const char *action, const char *value) {
  GError *error = NULL;
  GSubprocessLauncher *launcher = g_subprocess_launcher_new(G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_PIPE);
  g_subprocess_launcher_setenv(launcher, "LC_ALL", "C", TRUE);
  const char *argv[] = { m->bluetooth_command, "--timeout", "5", action, value, NULL };
  GSubprocess *process = g_subprocess_launcher_spawnv(launcher, argv, &error);
  g_object_unref(launcher);
  if (process) {
    m->bluetooth_busy = TRUE;
    m->refs++;
    g_subprocess_communicate_utf8_async(process, NULL, m->cancel, callback, m);
    g_object_unref(process);
  } else {
    gtk_label_set_text(GTK_LABEL(m->bluetooth_message), error->message);
    g_clear_error(&error);
  }
}

static gboolean bluetooth_refresh(gpointer data) {
  Module *m = data;
  if (!m->bluetooth_busy && m->bluetooth_command && gtk_widget_get_visible(m->power_menu))
    bluetooth_run(m, bluetooth_ready, "show", NULL);
  return G_SOURCE_CONTINUE;
}

static void bluetooth_set_ready(GObject *source, GAsyncResult *result, gpointer data) {
  Module *m = data;
  GError *error = NULL;
  char *output = NULL, *errors = NULL;
  gboolean ok = g_subprocess_communicate_utf8_finish(G_SUBPROCESS(source), result, &output, &errors, &error);
  if (!m->dead) {
    m->bluetooth_busy = FALSE;
    gtk_widget_set_sensitive(m->bluetooth_button, TRUE);
    if (!ok || !g_subprocess_get_successful(G_SUBPROCESS(source)))
      gtk_label_set_text(GTK_LABEL(m->bluetooth_message), error ? error->message :
          errors && *errors ? errors : output && *output ? output : "Could not change Bluetooth power");
    else bluetooth_refresh(m);
  }
  g_clear_error(&error);
  g_free(output);
  g_free(errors);
  unref_module(m);
}

static void bluetooth_toggle(GtkButton *button, gpointer data) {
  Module *m = data;
  if (m->bluetooth_busy || !m->bluetooth_command) return;
  bluetooth_run(m, bluetooth_set_ready, "power", m->bluetooth_powered ? "off" : "on");
  gtk_widget_set_sensitive(GTK_WIDGET(button), !m->bluetooth_busy);
}

static void bluetooth_settings(GtkButton *button, gpointer data) {
  (void)button;
  Module *m = data;
  GError *error = NULL;
  if (m->bluetooth_settings_command)
    g_spawn_command_line_async(m->bluetooth_settings_command, &error);
  if (error) gtk_label_set_text(GTK_LABEL(m->bluetooth_message), error->message);
  g_clear_error(&error);
}

static void settings_launch(GtkButton *button, gpointer data) {
  GError *error = NULL;
  g_spawn_command_line_async(data, &error);
  gtk_widget_set_tooltip_text(GTK_WIDGET(button), error ? error->message : NULL);
  g_clear_error(&error);
}

static const char *power_ids[] = { "performance", "balanced", "power-saver" };
static const char *power_names[] = { "Performance", "Balanced", "Power Saver" };
static const char *power_icons[] = {
  "power-profile-performance-symbolic", "power-profile-balanced-symbolic",
  "power-profile-power-saver-symbolic"
};

static void power_expand(GtkToggleButton *button, gpointer data) {
  gtk_revealer_set_reveal_child(GTK_REVEALER(data), gtk_toggle_button_get_active(button));
}

static void message_changed(GObject *label, GParamSpec *property, gpointer data) {
  (void)property; (void)data;
  gtk_widget_set_visible(GTK_WIDGET(label), *gtk_label_get_text(GTK_LABEL(label)) != '\0');
}

static GtkWidget *quick_tile(GtkWidget *button, const char *title, GtkWidget *icon,
                             GtkWidget *subtitle, gboolean arrow) {
  css(button, "quick-toggle");
  GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
  GtkWidget *labels = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
  GtkWidget *heading = gtk_label_new(title);
  gtk_label_set_xalign(GTK_LABEL(heading), 0);
  css(heading, "quick-toggle-title");
  gtk_box_pack_start(GTK_BOX(labels), heading, FALSE, FALSE, 0);
  if (subtitle) {
    gtk_label_set_xalign(GTK_LABEL(subtitle), 0);
    css(subtitle, "quick-toggle-subtitle");
    gtk_box_pack_start(GTK_BOX(labels), subtitle, FALSE, FALSE, 0);
  }
  gtk_box_pack_start(GTK_BOX(row), icon, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(row), labels, TRUE, TRUE, 0);
  if (arrow) gtk_box_pack_end(GTK_BOX(row),
      gtk_image_new_from_icon_name("go-next-symbolic", GTK_ICON_SIZE_MENU), FALSE, FALSE, 0);
  gtk_container_add(GTK_CONTAINER(button), row);
  return button;
}

static void update_power(Module *m) {
  GVariant *active = m->power ? g_dbus_proxy_get_cached_property(m->power, "ActiveProfile") : NULL;
  GVariant *profiles = m->power ? g_dbus_proxy_get_cached_property(m->power, "Profiles") : NULL;
  GVariant *inhibited = m->power ? g_dbus_proxy_get_cached_property(m->power, "PerformanceInhibited") : NULL;
  const char *current = active ? g_variant_get_string(active, NULL) : "";
  gtk_label_set_text(GTK_LABEL(m->power_label), "Power Mode");
  for (guint i = 0; i < G_N_ELEMENTS(power_ids); i++) {
    gboolean available = FALSE;
    if (profiles) {
      GVariantIter iter;
      GVariant *entry;
      g_variant_iter_init(&iter, profiles);
      while ((entry = g_variant_iter_next_value(&iter))) {
        const char *id = NULL;
        if (g_variant_lookup(entry, "Profile", "&s", &id) && g_str_equal(id, power_ids[i]))
          available = TRUE;
        g_variant_unref(entry);
      }
    }
    gboolean selected = g_str_equal(current, power_ids[i]);
    GtkStyleContext *style = gtk_widget_get_style_context(m->power_buttons[i]);
    if (selected) gtk_style_context_add_class(style, "profile-selected");
    else gtk_style_context_remove_class(style, "profile-selected");
    char *label = g_strdup_printf("%s%s", power_names[i], selected ? "  ✓" : "");
    gtk_button_set_label(GTK_BUTTON(m->power_buttons[i]), label);
    gtk_widget_set_visible(m->power_buttons[i], available);
    gboolean blocked = i == 0 && inhibited && *g_variant_get_string(inhibited, NULL);
    gtk_widget_set_sensitive(m->power_buttons[i], !m->power_pending && !blocked);
    gtk_widget_set_tooltip_text(m->power_buttons[i], blocked ? g_variant_get_string(inhibited, NULL) : NULL);
    if (selected) {
      gtk_label_set_text(GTK_LABEL(m->power_label), power_names[i]);
      gtk_image_set_from_icon_name(GTK_IMAGE(m->power_icon), power_icons[i], GTK_ICON_SIZE_MENU);
    }
    g_free(label);
  }
  if (!m->power_pending)
    gtk_label_set_text(GTK_LABEL(m->power_message), active ? "" : "Power profiles unavailable");
  g_clear_pointer(&active, g_variant_unref);
  g_clear_pointer(&profiles, g_variant_unref);
  g_clear_pointer(&inhibited, g_variant_unref);
}

static void power_changed(GDBusProxy *proxy, GVariant *changed, const char *const *invalidated, gpointer data) {
  (void)proxy; (void)changed; (void)invalidated;
  update_power(data);
}

static void power_set_ready(GObject *source, GAsyncResult *result, gpointer data) {
  Module *m = data;
  GError *error = NULL;
  GVariant *reply = g_dbus_proxy_call_finish(G_DBUS_PROXY(source), result, &error);
  if (!m->dead) {
    m->power_pending = FALSE;
    update_power(m);
    gtk_label_set_text(GTK_LABEL(m->power_message), error ? error->message : "");
  }
  g_clear_pointer(&reply, g_variant_unref);
  g_clear_error(&error);
  unref_module(m);
}

static void power_select(GtkButton *button, gpointer data) {
  Module *m = data;
  const char *id = g_object_get_data(G_OBJECT(button), "profile");
  if (!m->power || m->power_pending) return;
  m->power_pending = TRUE;
  update_power(m);
  gtk_label_set_text(GTK_LABEL(m->power_message), "Switching…");
  m->refs++;
  g_dbus_proxy_call(m->power, "org.freedesktop.DBus.Properties.Set",
      g_variant_new("(ssv)", "org.freedesktop.UPower.PowerProfiles", "ActiveProfile",
                    g_variant_new_string(id)),
      G_DBUS_CALL_FLAGS_ALLOW_INTERACTIVE_AUTHORIZATION, -1, m->cancel, power_set_ready, m);
}

static void power_ready(GObject *source, GAsyncResult *result, gpointer data) {
  (void)source;
  Module *m = data;
  GError *error = NULL;
  GDBusProxy *proxy = g_dbus_proxy_new_for_bus_finish(result, &error);
  if (!m->dead) {
    m->power = g_steal_pointer(&proxy);
    if (m->power)
      g_signal_connect(m->power, "g-properties-changed", G_CALLBACK(power_changed), m);
    update_power(m);
    if (error) gtk_label_set_text(GTK_LABEL(m->power_message), error->message);
  }
  g_clear_object(&proxy);
  g_clear_error(&error);
  unref_module(m);
}

static gboolean power_click(GtkWidget *widget, GdkEventButton *event, gpointer data) {
  (void)widget;
  Module *m = data;
  if (event->button != 1) return FALSE;
  if (gtk_widget_get_visible(m->power_menu)) gtk_popover_popdown(GTK_POPOVER(m->power_menu));
  else {
    gtk_popover_popup(GTK_POPOVER(m->power_menu));
    bluetooth_refresh(m);
  }
  return TRUE;
}

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

static void calendar_refresh(Module *m) {
  GDateTime *now = g_date_time_new_now_local();
  char *weekday = g_date_time_format(now, "%A");
  char *date = g_date_time_format(now, "%B %-d %Y");
  char *month = g_date_time_format(m->calendar_selected, "%B %Y");
  gtk_label_set_text(GTK_LABEL(m->calendar_weekday), weekday);
  gtk_label_set_text(GTK_LABEL(m->calendar_date), date);
  gtk_button_set_label(GTK_BUTTON(m->calendar_month), month);
  g_free(weekday);
  g_free(date);
  g_free(month);
  GDateTime *first = g_date_time_add_days(m->calendar_selected,
      1 - g_date_time_get_day_of_month(m->calendar_selected));
  GDateTime *start = g_date_time_add_days(first, -(g_date_time_get_day_of_week(first) % 7));
  for (guint i = 0; i < G_N_ELEMENTS(m->calendar_days); i++) {
    GDateTime *day = g_date_time_add_days(start, i);
    GtkWidget *button = m->calendar_days[i];
    char *label = g_date_time_format(day, "%-d");
    gtk_button_set_label(GTK_BUTTON(button), label);
    g_free(label);
    g_object_set_data_full(G_OBJECT(button), "date", day, (GDestroyNotify)g_date_time_unref);
    GtkStyleContext *style = gtk_widget_get_style_context(button);
    const char *classes[] = { "calendar-other-month", "calendar-today", "calendar-selected" };
    gboolean active[] = {
      g_date_time_get_month(day) != g_date_time_get_month(first),
      g_date_time_get_year(day) == g_date_time_get_year(now) &&
        g_date_time_get_day_of_year(day) == g_date_time_get_day_of_year(now),
      g_date_time_get_day_of_month(day) == g_date_time_get_day_of_month(m->calendar_selected) &&
        g_date_time_get_month(day) == g_date_time_get_month(m->calendar_selected)
    };
    for (guint j = 0; j < G_N_ELEMENTS(classes); j++) {
      if (active[j]) gtk_style_context_add_class(style, classes[j]);
      else gtk_style_context_remove_class(style, classes[j]);
    }
  }
  g_date_time_unref(start);
  g_date_time_unref(first);
  g_date_time_unref(now);
}

static void calendar_select(GtkButton *button, gpointer data) {
  Module *m = data;
  GDateTime *day = g_date_time_ref(g_object_get_data(G_OBJECT(button), "date"));
  g_date_time_unref(m->calendar_selected);
  m->calendar_selected = day;
  calendar_refresh(m);
}

static void calendar_navigate(GtkButton *button, gpointer data) {
  Module *m = data;
  int offset = button ? GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "month-offset")) : 0;
  GDateTime *day = offset ? g_date_time_add_months(m->calendar_selected, offset)
      : g_date_time_new_now_local();
  if (!day) return;
  g_date_time_unref(m->calendar_selected);
  m->calendar_selected = day;
  calendar_refresh(m);
}

static void make_calendar(Module *m) {
  GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
  gtk_container_add(GTK_CONTAINER(m->calendar), box);
  GtkWidget *today = gtk_button_new();
  css(today, "calendar-today-button");
  g_signal_connect(today, "clicked", G_CALLBACK(calendar_navigate), m);
  GtkWidget *heading = gtk_box_new(GTK_ORIENTATION_VERTICAL, 3);
  m->calendar_weekday = gtk_label_new("");
  m->calendar_date = gtk_label_new("");
  css(m->calendar_weekday, "calendar-weekday-label");
  css(m->calendar_date, "calendar-date-label");
  gtk_label_set_xalign(GTK_LABEL(m->calendar_weekday), 0);
  gtk_label_set_xalign(GTK_LABEL(m->calendar_date), 0);
  gtk_container_add(GTK_CONTAINER(heading), m->calendar_weekday);
  gtk_container_add(GTK_CONTAINER(heading), m->calendar_date);
  gtk_container_add(GTK_CONTAINER(today), heading);
  gtk_box_pack_start(GTK_BOX(box), today, FALSE, FALSE, 0);
  GtkWidget *header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
  gtk_box_pack_start(GTK_BOX(box), header, FALSE, FALSE, 0);
  m->calendar_month = gtk_button_new();
  g_signal_connect(m->calendar_month, "clicked", G_CALLBACK(calendar_navigate), m);
  for (int offset = -1; offset <= 1; offset += 2) {
    GtkWidget *arrow = gtk_button_new_from_icon_name(offset < 0 ?
        "pan-start-symbolic" : "pan-end-symbolic", GTK_ICON_SIZE_MENU);
    css(arrow, "calendar-pager");
    gtk_widget_set_tooltip_text(arrow, offset < 0 ? "Previous month" : "Next month");
    g_object_set_data(G_OBJECT(arrow), "month-offset", GINT_TO_POINTER(offset));
    g_signal_connect(arrow, "clicked", G_CALLBACK(calendar_navigate), m);
    gtk_box_pack_start(GTK_BOX(header), arrow, FALSE, FALSE, 0);
    if (offset == -1) gtk_box_pack_start(GTK_BOX(header), m->calendar_month, TRUE, TRUE, 0);
  }
  GtkWidget *grid = gtk_grid_new();
  gtk_grid_set_column_homogeneous(GTK_GRID(grid), TRUE);
  gtk_grid_set_row_homogeneous(GTK_GRID(grid), TRUE);
  gtk_box_pack_start(GTK_BOX(box), grid, FALSE, FALSE, 0);
  /* A known Sunday supplies localized weekday names. */
  GDateTime *sunday = g_date_time_new_local(2024, 1, 7, 12, 0, 0);
  for (int i = 0; i < 7; i++) {
    GDateTime *day = g_date_time_add_days(sunday, i);
    char *name = g_date_time_format(day, "%a");
    char *letter = g_strndup(name, g_utf8_next_char(name) - name);
    GtkWidget *label = gtk_label_new(letter);
    css(label, "calendar-day-heading");
    gtk_widget_set_tooltip_text(label, name);
    gtk_grid_attach(GTK_GRID(grid), label, i, 0, 1, 1);
    g_free(letter);
    g_free(name);
    g_date_time_unref(day);
  }
  g_date_time_unref(sunday);
  for (guint i = 0; i < G_N_ELEMENTS(m->calendar_days); i++) {
    GtkWidget *day = m->calendar_days[i] = gtk_button_new();
    gtk_widget_set_halign(day, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(day, GTK_ALIGN_CENTER);
    css(day, "calendar-day");
    if (i % 7 == 0 || i % 7 == 6) css(day, "calendar-weekend");
    g_signal_connect(day, "clicked", G_CALLBACK(calendar_select), m);
    gtk_grid_attach(GTK_GRID(grid), day, i % 7, 1 + i / 7, 1, 1);
  }
  m->calendar_selected = g_date_time_new_now_local();
  calendar_refresh(m);
  gtk_widget_show_all(box);
}

static gboolean clock_click(GtkWidget *widget, GdkEventButton *event, gpointer data) {
  (void)widget;
  Module *m = data;
  if (event->button != 1) return FALSE;
  if (gtk_widget_get_visible(m->calendar)) gtk_popover_popdown(GTK_POPOVER(m->calendar));
  else {
    calendar_navigate(NULL, m);
    gtk_popover_popup(GTK_POPOVER(m->calendar));
  }
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
      if (!m->status)
        g_signal_connect(item->box, "button-press-event", G_CALLBACK(item_click), item);
    }
    const char *icon = text(o, "icon");
    if (m->network_icon && g_str_has_prefix(icon, "network-")) {
      gtk_image_set_from_icon_name(GTK_IMAGE(m->network_icon), icon, GTK_ICON_SIZE_MENU);
      gtk_label_set_text(GTK_LABEL(m->network_label), text(o, "tooltip"));
    }
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
  g_clear_object(&m->power);
  g_free(m->command);
  g_free(m->bluetooth_command);
  g_free(m->bluetooth_settings_command);
  g_free(m->network_settings_command);
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
  } else if (m->status) {
    m->power_icon = gtk_image_new_from_icon_name(power_icons[1], GTK_ICON_SIZE_MENU);
    m->power_label = gtk_label_new("Power Mode");
    m->power_menu = gtk_popover_new(m->root);
    gtk_popover_set_constrain_to(GTK_POPOVER(m->power_menu), GTK_POPOVER_CONSTRAINT_NONE);
    gtk_popover_set_position(GTK_POPOVER(m->power_menu), GTK_POS_BOTTOM);
    css(m->power_menu, "gnome-power-menu");
    GtkWidget *menu = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_container_add(GTK_CONTAINER(m->power_menu), menu);
    GtkWidget *tiles = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(tiles), 12);
    gtk_grid_set_column_spacing(GTK_GRID(tiles), 12);
    gtk_grid_set_column_homogeneous(GTK_GRID(tiles), TRUE);
    gtk_box_pack_start(GTK_BOX(menu), tiles, FALSE, FALSE, 0);
    m->network_icon = gtk_image_new_from_icon_name("network-wireless-symbolic", GTK_ICON_SIZE_MENU);
    m->network_label = gtk_label_new("Connections");
    GtkWidget *network = quick_tile(gtk_button_new(), "Network", m->network_icon, m->network_label, TRUE);
    gtk_grid_attach(GTK_GRID(tiles), network, 0, 0, 1, 1);
    m->network_settings_command = config_string(entries, length, "network-settings-command");
    if (m->network_settings_command)
      g_signal_connect(network, "clicked", G_CALLBACK(settings_launch), m->network_settings_command);
    GtkWidget *bluetooth = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    css(bluetooth, "quick-split");
    m->bluetooth_label = gtk_label_new("Off");
    m->bluetooth_button = quick_tile(gtk_button_new(), "Bluetooth",
        gtk_image_new_from_icon_name("bluetooth-active-symbolic", GTK_ICON_SIZE_MENU),
        m->bluetooth_label, FALSE);
    gtk_widget_set_sensitive(m->bluetooth_button, FALSE);
    g_signal_connect(m->bluetooth_button, "clicked", G_CALLBACK(bluetooth_toggle), m);
    gtk_box_pack_start(GTK_BOX(bluetooth), m->bluetooth_button, TRUE, TRUE, 0);
    GtkWidget *devices = gtk_button_new_from_icon_name("go-next-symbolic", GTK_ICON_SIZE_MENU);
    css(devices, "quick-menu-arrow");
    gtk_widget_set_tooltip_text(devices, "Bluetooth Settings");
    g_signal_connect(devices, "clicked", G_CALLBACK(bluetooth_settings), m);
    gtk_box_pack_start(GTK_BOX(bluetooth), devices, FALSE, FALSE, 0);
    gtk_grid_attach(GTK_GRID(tiles), bluetooth, 1, 0, 1, 1);
    GtkWidget *power = quick_tile(gtk_toggle_button_new(), "Power Mode", m->power_icon, m->power_label, TRUE);
    gtk_grid_attach(GTK_GRID(tiles), power, 0, 1, 1, 1);
    GtkWidget *sound = quick_tile(gtk_button_new(), "Sound",
        gtk_image_new_from_icon_name("audio-volume-high-symbolic", GTK_ICON_SIZE_MENU), NULL, TRUE);
    g_signal_connect(sound, "clicked", G_CALLBACK(settings_launch), "pavucontrol");
    gtk_grid_attach(GTK_GRID(tiles), sound, 1, 1, 1, 1);
    GtkWidget *profiles = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    css(profiles, "quick-toggle-menu");
    GtkWidget *heading = gtk_label_new("Power Mode");
    gtk_label_set_xalign(GTK_LABEL(heading), 0);
    css(heading, "quick-menu-title");
    gtk_box_pack_start(GTK_BOX(profiles), heading, FALSE, FALSE, 0);
    for (guint i = 0; i < G_N_ELEMENTS(power_ids); i++) {
      m->power_buttons[i] = gtk_button_new_with_label(power_names[i]);
      css(m->power_buttons[i], "profile-choice");
      gtk_label_set_xalign(GTK_LABEL(gtk_bin_get_child(GTK_BIN(m->power_buttons[i]))), 0);
      g_object_set_data(G_OBJECT(m->power_buttons[i]), "profile", (gpointer)power_ids[i]);
      g_signal_connect(m->power_buttons[i], "clicked", G_CALLBACK(power_select), m);
      gtk_box_pack_start(GTK_BOX(profiles), m->power_buttons[i], FALSE, FALSE, 0);
    }
    GtkWidget *revealer = gtk_revealer_new();
    gtk_container_add(GTK_CONTAINER(revealer), profiles);
    gtk_box_pack_start(GTK_BOX(menu), revealer, FALSE, FALSE, 0);
    g_signal_connect(power, "toggled", G_CALLBACK(power_expand), revealer);
    m->power_message = gtk_label_new("Connecting…");
    m->bluetooth_message = gtk_label_new("");
    GtkWidget *messages[] = { m->power_message, m->bluetooth_message };
    for (guint i = 0; i < G_N_ELEMENTS(messages); i++) {
      gtk_label_set_line_wrap(GTK_LABEL(messages[i]), TRUE);
      gtk_label_set_max_width_chars(GTK_LABEL(messages[i]), 40);
      css(messages[i], "quick-message");
      gtk_widget_set_no_show_all(messages[i], TRUE);
      g_signal_connect(messages[i], "notify::label", G_CALLBACK(message_changed), NULL);
      message_changed(G_OBJECT(messages[i]), NULL, NULL);
      gtk_box_pack_start(GTK_BOX(menu), messages[i], FALSE, FALSE, 0);
    }
    m->bluetooth_command = config_string(entries, length, "bluetooth-command");
    m->bluetooth_settings_command = config_string(entries, length, "bluetooth-settings-command");
    m->bluetooth_timer = g_timeout_add_seconds(5, bluetooth_refresh, m);
    gtk_widget_show_all(menu);
    update_power(m);
    g_signal_connect(m->root, "button-press-event", G_CALLBACK(power_click), m);
    m->refs++;
    g_dbus_proxy_new_for_bus(G_BUS_TYPE_SYSTEM, G_DBUS_PROXY_FLAGS_NONE, NULL,
        "org.freedesktop.UPower.PowerProfiles", "/org/freedesktop/UPower/PowerProfiles",
        "org.freedesktop.UPower.PowerProfiles", m->cancel, power_ready, m);
  } else if (g_strcmp0(kind, "clock") == 0) {
    m->clock = gtk_label_new("");
    gtk_container_add(GTK_CONTAINER(m->box), m->clock);
    m->calendar = gtk_popover_new(m->root);
    /* A layer-shell panel is only bar-height; let the calendar extend below it. */
    gtk_popover_set_constrain_to(GTK_POPOVER(m->calendar), GTK_POPOVER_CONSTRAINT_NONE);
    gtk_popover_set_position(GTK_POPOVER(m->calendar), GTK_POS_BOTTOM);
    css(m->calendar, "gnome-calendar");
    make_calendar(m);
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
  if (m->bluetooth_timer) g_source_remove(m->bluetooth_timer);
  if (m->calendar) gtk_widget_destroy(m->calendar);
  if (m->calendar_selected) g_date_time_unref(m->calendar_selected);
  if (m->power_menu) gtk_widget_destroy(m->power_menu);
  if (m->power) g_signal_handlers_disconnect_by_data(m->power, m);
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
