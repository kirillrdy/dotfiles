#include "../waybar-gnome.c"

static void set_property(Module *m, const char *name, GVariant *value) {
  g_dbus_proxy_set_cached_property(m->power, name, value);
  update_power(m);
}

static void bluetooth_output(Module *m, const char *output) {
  GError *error = NULL;
  GSubprocess *process = g_subprocess_new(G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_PIPE,
      &error, "printf", "%s", output, NULL);
  g_assert_no_error(error);
  m->refs++;
  m->bluetooth_busy = TRUE;
  g_subprocess_communicate_utf8_async(process, NULL, NULL, bluetooth_ready, m);
  while (m->bluetooth_busy) g_main_context_iteration(NULL, TRUE);
  g_object_unref(process);
}

static GtkContainer *root_widget(WaybarModule *module) {
  return GTK_CONTAINER(module);
}

int main(int argc, char **argv) {
  gtk_init(&argc, &argv);
  if (argc > 1) {
    GtkCssProvider *provider = gtk_css_provider_new();
    GError *error = NULL;
    gtk_css_provider_load_from_path(provider, argv[1], &error);
    g_assert_no_error(error);
    gtk_style_context_add_provider_for_screen(gdk_screen_get_default(),
        GTK_STYLE_PROVIDER(provider), GTK_STYLE_PROVIDER_PRIORITY_USER);
    g_object_unref(provider);
  }
  Module m = {0};
  m.refs = 1;
  m.power = g_object_new(G_TYPE_DBUS_PROXY, "g-interface-name",
      "org.freedesktop.UPower.PowerProfiles", NULL);
  m.power_label = gtk_label_new("");
  m.power_icon = gtk_image_new();
  m.power_message = gtk_label_new("");
  GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  g_object_ref_sink(box);
  gtk_container_add(GTK_CONTAINER(box), m.power_label);
  gtk_container_add(GTK_CONTAINER(box), m.power_icon);
  gtk_container_add(GTK_CONTAINER(box), m.power_message);
  m.bluetooth_button = gtk_button_new();
  m.bluetooth_label = gtk_label_new("");
  gtk_container_add(GTK_CONTAINER(m.bluetooth_button), m.bluetooth_label);
  m.bluetooth_message = gtk_label_new("");
  gtk_container_add(GTK_CONTAINER(box), m.bluetooth_button);
  gtk_container_add(GTK_CONTAINER(box), m.bluetooth_message);
  for (guint i = 0; i < 3; i++) {
    m.power_buttons[i] = gtk_button_new();
    gtk_container_add(GTK_CONTAINER(box), m.power_buttons[i]);
  }
  update_power(&m);
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(m.power_message)), ==, "Power profiles unavailable");
  for (guint i = 0; i < 3; i++) g_assert_false(gtk_widget_get_visible(m.power_buttons[i]));

  GError *error = NULL;
  GVariant *profiles = g_variant_parse(G_VARIANT_TYPE("aa{sv}"),
      "[{'Profile': <'balanced'>}, {'Profile': <'power-saver'>}]", NULL, NULL, &error);
  g_assert_no_error(error);
  set_property(&m, "Profiles", profiles);
  g_variant_unref(profiles);
  set_property(&m, "ActiveProfile", g_variant_new_string("balanced"));
  g_assert_false(gtk_widget_get_visible(m.power_buttons[0]));
  g_assert_true(gtk_widget_get_visible(m.power_buttons[1]));
  g_assert_true(gtk_widget_get_visible(m.power_buttons[2]));
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(m.power_label)), ==, "Balanced");
  g_assert_cmpstr(gtk_button_get_label(GTK_BUTTON(m.power_buttons[1])), ==, "Balanced  ✓");

  /* External profile changes update the label and selection. */
  set_property(&m, "ActiveProfile", g_variant_new_string("power-saver"));
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(m.power_label)), ==, "Power Saver");
  g_assert_cmpstr(gtk_button_get_label(GTK_BUTTON(m.power_buttons[1])), ==, "Balanced");
  g_assert_cmpstr(gtk_button_get_label(GTK_BUTTON(m.power_buttons[2])), ==, "Power Saver  ✓");
  m.power_pending = TRUE;
  update_power(&m);
  g_assert_false(gtk_widget_get_sensitive(m.power_buttons[2]));
  m.power_pending = FALSE;
  update_power(&m);
  g_assert_true(gtk_widget_get_sensitive(m.power_buttons[2]));

  profiles = g_variant_parse(G_VARIANT_TYPE("aa{sv}"),
      "[{'Profile': <'performance'>}, {'Profile': <'balanced'>}, {'Profile': <'power-saver'>}]",
      NULL, NULL, &error);
  g_assert_no_error(error);
  set_property(&m, "Profiles", profiles);
  g_variant_unref(profiles);
  g_assert_true(gtk_widget_get_visible(m.power_buttons[0]));
  set_property(&m, "PerformanceInhibited", g_variant_new_string("lap-detected"));
  g_assert_false(gtk_widget_get_sensitive(m.power_buttons[0]));
  g_assert_true(gtk_widget_get_sensitive(m.power_buttons[1]));
  set_property(&m, "PerformanceInhibited", g_variant_new_string(""));
  g_assert_true(gtk_widget_get_sensitive(m.power_buttons[0]));

  bluetooth_output(&m, "Controller 00:11:22:33:44:55\n\tPowered: yes\n");
  g_assert_true(m.bluetooth_powered);
  g_assert_true(gtk_style_context_has_class(gtk_widget_get_style_context(m.bluetooth_button), "quick-active"));
  g_assert_true(gtk_widget_get_sensitive(m.bluetooth_button));
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(m.bluetooth_label)), ==, "On");
  bluetooth_output(&m, "Controller 00:11:22:33:44:55\n\tPowered: no\n");
  g_assert_false(m.bluetooth_powered);
  g_assert_false(gtk_style_context_has_class(gtk_widget_get_style_context(m.bluetooth_button), "quick-active"));
  g_assert_true(gtk_widget_get_sensitive(m.bluetooth_button));
  bluetooth_output(&m, "No default controller available\n");
  g_assert_false(gtk_widget_get_sensitive(m.bluetooth_button));
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(m.bluetooth_message)), ==, "Bluetooth unavailable");

  /* Status icons share a single popup containing both settings. */
  GtkWidget *root = gtk_event_box_new();
  g_object_ref_sink(root);
  InitInfo info = { .obj = (WaybarModule *)root, .get_root_widget = root_widget };
  const ConfigEntry config[] = { {"name", "\"gnome-status\""}, {"kind", "\"indicator\""} };
  Module *status = wbcffi_init(&info, config, G_N_ELEMENTS(config));
  g_assert_true(gtk_widget_is_ancestor(status->power_label, status->power_menu));
  g_assert_true(gtk_widget_is_ancestor(status->bluetooth_button, status->power_menu));
  g_assert_true(gtk_widget_is_ancestor(status->network_icon, status->power_menu));
  g_assert_false(gtk_widget_is_ancestor(status->power_label, status->box));
  update_line(status, "{\"items\":[{\"icon\":\"bluetooth-active-symbolic\"},{\"icon\":\"battery-level-80-symbolic\"}]}");
  g_assert_true(gtk_widget_get_visible(status->item[0].box));
  g_assert_true(gtk_widget_get_visible(status->item[1].box));
  update_line(status, "{\"items\":[{\"icon\":\"network-wired-symbolic\",\"tooltip\":\"Wired network\"}]}");
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(status->network_label)), ==, "Wired network");
  wbcffi_deinit(status);
  while (g_main_context_iteration(NULL, FALSE)) {}
  gtk_widget_destroy(root);
  g_object_unref(root);

  /* Calendar navigation handles leap days, year boundaries and spillover days. */
  root = gtk_event_box_new();
  g_object_ref_sink(root);
  info.obj = (WaybarModule *)root;
  const ConfigEntry clock_config[] = { {"kind", "\"clock\""} };
  Module *clock = wbcffi_init(&info, clock_config, G_N_ELEMENTS(clock_config));
  g_date_time_unref(clock->calendar_selected);
  clock->calendar_selected = g_date_time_new_local(2024, 2, 29, 12, 0, 0);
  calendar_refresh(clock);
  /* February 2024 starts on Thursday, so leap day occupies cell 32. */
  g_assert_cmpstr(gtk_button_get_label(GTK_BUTTON(clock->calendar_days[32])), ==, "29");
  g_assert_true(gtk_style_context_has_class(
      gtk_widget_get_style_context(clock->calendar_days[32]), "calendar-selected"));
  calendar_select(GTK_BUTTON(clock->calendar_days[33]), clock);
  g_assert_cmpint(g_date_time_get_month(clock->calendar_selected), ==, 3);
  g_assert_cmpint(g_date_time_get_day_of_month(clock->calendar_selected), ==, 1);
  GtkWidget *next = gtk_button_new();
  g_object_ref_sink(next);
  g_object_set_data(G_OBJECT(next), "month-offset", GINT_TO_POINTER(-1));
  calendar_navigate(GTK_BUTTON(next), clock);
  calendar_navigate(GTK_BUTTON(next), clock);
  calendar_navigate(GTK_BUTTON(next), clock);
  g_assert_cmpint(g_date_time_get_year(clock->calendar_selected), ==, 2023);
  g_assert_cmpint(g_date_time_get_month(clock->calendar_selected), ==, 12);
  calendar_navigate(NULL, clock);
  GDateTime *now = g_date_time_new_now_local();
  g_assert_cmpint(g_date_time_get_year(clock->calendar_selected), ==, g_date_time_get_year(now));
  g_assert_cmpint(g_date_time_get_day_of_year(clock->calendar_selected), ==, g_date_time_get_day_of_year(now));
  g_date_time_unref(now);
  gtk_widget_destroy(next);
  g_object_unref(next);
  wbcffi_deinit(clock);
  gtk_widget_destroy(root);
  g_object_unref(root);

  gtk_widget_destroy(box);
  g_object_unref(box);
  g_object_unref(m.power);
  return 0;
}
