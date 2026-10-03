/*
 * SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
 * SPDX-License-Identifier: MIT
 *
 * The plugin, loaded the way phosh loads it, and then driven through sysfs.
 *
 * Not "does it compile": phosh finds this thing through a GIO extension
 * point, and everything that can go wrong there goes wrong silently - a
 * module that is never scanned, a name that does not match the one in the
 * settings, a type that is not a GtkWidget. The shell says one line,
 * "Custom status-icon '…' not found", and carries on without it.
 *
 * So this does what phosh's src/plugin-loader.c does: register the extension
 * point, scan the directory, ask for the extension by the name the settings
 * will hold, build the widget - and then move the switches under it.
 *
 * The switches are a directory of files here, pointed at with the same
 * environment variable the daemon's tests use, and so is furios-switch-mask's
 * directory: on a phone where the mask is in use the real one would hide
 * every icon this test waits for. Nothing in this test touches the real
 * ones, and it needs no phone: what it checks is the part that is ours -
 * which files make an icon appear, and which do not.
 *
 * When the plugin reads is counted with inotify on the switch directory: a
 * read is an open, and the plugin opens nothing else there.
 */

#include <gtk/gtk.h>
#include <gio/gio.h>
#include <glib/gstdio.h>
#include <phosh-plugin.h>
#include <sys/inotify.h>
#include <unistd.h>

#define PLUGIN_NAME "furios-killswitch"

static int checks = 0;
static int failures = 0;
static char *base = NULL;
static char *mask = NULL;
static int reads_fd = -1;


static void
ok (const char *what)
{
  checks++;
  g_print ("  \033[32mok\033[0m   %s\n", what);
}


static void
fail (const char *what, const char *detail)
{
  checks++;
  failures++;
  g_print ("  \033[31mFAIL\033[0m %s\n       %s\n", what, detail ? detail : "");
}


static void
check_true (const char *what, gboolean value)
{
  if (value)
    ok (what);
  else
    fail (what, "expected true");
}


static void
set_switch (const char *attribute, const char *text)
{
  g_autofree char *path = g_build_filename (base, attribute, NULL);
  g_autoptr (GError) error = NULL;

  if (text == NULL) {
    g_remove (path);
    return;
  }
  if (!g_file_set_contents (path, text, -1, &error))
    g_error ("could not write %s: %s", path, error->message);
}


static GtkWidget *
image_at (GtkWidget *widget, int index)
{
  GList *children = gtk_container_get_children (GTK_CONTAINER (widget));
  GtkWidget *image = g_list_nth_data (children, index);

  g_list_free (children);

  return image;
}


/*
 * Wait for the widget to say what it should, pumping the main loop.
 *
 * The switch is read on a timer, so nothing here can be asserted on the next
 * line. The interval is a second in this test (see run-tests.sh), and three
 * is long enough for one tick to have happened and short enough that a
 * broken test does not hang a suite.
 */
static gboolean
settles_to (GtkWidget *widget, gboolean cam, gboolean nwk)
{
  gint64 deadline = g_get_monotonic_time () + 3 * G_USEC_PER_SEC;

  while (g_get_monotonic_time () < deadline) {
    gboolean any = cam || nwk;

    if (gtk_widget_get_visible (widget) == any &&
        gtk_widget_get_visible (image_at (widget, 0)) == cam &&
        gtk_widget_get_visible (image_at (widget, 1)) == nwk)
      return TRUE;

    g_main_context_iteration (NULL, FALSE);
    g_usleep (10 * 1000);
  }

  return FALSE;
}


/* Stand-ins for phosh's radio icons: the plugin knows them by type name and
   reads their "icon-name", and a GtkImage has one. */
static GType
fake_type (const char *name)
{
  GTypeQuery query;

  g_type_query (GTK_TYPE_IMAGE, &query);
  return g_type_register_static_simple (GTK_TYPE_IMAGE, name,
                                        query.class_size, NULL,
                                        query.instance_size, NULL, 0);
}


static GtkWidget *
radio_icon (GType type, const char *icon)
{
  GtkWidget *image = g_object_new (type, "icon-name", icon, NULL);

  gtk_widget_set_visible (image, TRUE);
  return image;
}


static void
set_mask (const char *attribute, gboolean present)
{
  g_autofree char *path = g_build_filename (mask, attribute, NULL);

  if (!present)
    g_remove (path);
  else if (!g_file_set_contents (path, "1\n", -1, NULL))
    g_error ("could not write %s", path);
}


/* Opens of the two switch files since the last call. The test's own writes
   go through a temporary name and a rename, and are not counted. */
static int
drain_reads (void)
{
  char buffer[4096] __attribute__ ((aligned (__alignof__ (struct inotify_event))));
  int count = 0;
  ssize_t len;

  while ((len = read (reads_fd, buffer, sizeof buffer)) > 0) {
    for (char *p = buffer; p < buffer + len;) {
      struct inotify_event *event = (struct inotify_event *) p;

      if (event->len > 0 &&
          (g_str_equal (event->name, "cam_switch") ||
           g_str_equal (event->name, "nwk_switch")))
        count++;
      p += sizeof (struct inotify_event) + event->len;
    }
  }
  return count;
}


/* How often the switches are read while the main loop runs for 1.5 s - one
   and a half intervals in this test, so a live timer reads at least once. */
static int
reads_while_running (void)
{
  gint64 deadline = g_get_monotonic_time () + 1500 * 1000;
  int count;

  drain_reads ();
  count = 0;
  while (g_get_monotonic_time () < deadline) {
    g_main_context_iteration (NULL, FALSE);
    g_usleep (10 * 1000);
    count += drain_reads ();
  }
  return count;
}


/* phosh's monitor manager, as much of it as the plugin uses: the
   PowerSaveMode of org.gnome.Mutter.DisplayConfig, 0 on and 3 off. The two
   functions below are the ones phosh exports, found by the plugin in this
   program the same way (the test is linked with -rdynamic). */
typedef struct { GObject parent; int mode; } FakeMonitors;
typedef struct { GObjectClass parent_class; } FakeMonitorsClass;
G_DEFINE_TYPE (FakeMonitors, fake_monitors, G_TYPE_OBJECT)

static void
fake_monitors_get_property (GObject *object, guint id, GValue *value, GParamSpec *pspec)
{
  g_value_set_int (value, ((FakeMonitors *) object)->mode);
}

static void
fake_monitors_set_property (GObject *object, guint id, const GValue *value, GParamSpec *pspec)
{
  ((FakeMonitors *) object)->mode = g_value_get_int (value);
  g_object_notify_by_pspec (object, pspec);
}

static void
fake_monitors_class_init (FakeMonitorsClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->get_property = fake_monitors_get_property;
  object_class->set_property = fake_monitors_set_property;
  g_object_class_install_property (object_class, 1,
    g_param_spec_int ("power-save-mode", NULL, NULL, 0, 3, 0,
                      G_PARAM_READWRITE | G_PARAM_EXPLICIT_NOTIFY));
}

static void
fake_monitors_init (FakeMonitors *self)
{
}

static GObject *fake_monitors = NULL;

G_MODULE_EXPORT gpointer phosh_shell_get_default (void);
G_MODULE_EXPORT GObject *phosh_shell_get_monitor_manager (gpointer shell);

G_MODULE_EXPORT gpointer
phosh_shell_get_default (void)
{
  return &fake_monitors;
}

G_MODULE_EXPORT GObject *
phosh_shell_get_monitor_manager (gpointer shell)
{
  return shell == &fake_monitors ? fake_monitors : NULL;
}


/* Pump the main loop until `widget` has the visibility asked for. */
static gboolean
visible_settles_to (GtkWidget *widget, gboolean visible)
{
  gint64 deadline = g_get_monotonic_time () + 3 * G_USEC_PER_SEC;

  while (g_get_monotonic_time () < deadline) {
    if (gtk_widget_get_visible (widget) == visible)
      return TRUE;
    g_main_context_iteration (NULL, FALSE);
    g_usleep (10 * 1000);
  }
  return FALSE;
}


int
main (int argc, char *argv[])
{
  GIOExtensionPoint *ep;
  GIOExtension *extension;
  GtkWidget *widget;
  GType type;

  if (argc < 2) {
    g_printerr ("usage: %s <directory holding the built plugin>\n", argv[0]);
    return 2;
  }

  base = g_dir_make_tmp ("killswitch-icons-test-XXXXXX", NULL);
  if (base == NULL)
    g_error ("no temporary directory to put the switches in");
  g_setenv ("FURIOS_KILLSWITCH_BASE", base, TRUE);
  g_setenv ("FURIOS_KILLSWITCH_INTERVAL", "1", TRUE);
  mask = g_dir_make_tmp ("killswitch-icons-mask-XXXXXX", NULL);
  if (mask == NULL)
    g_error ("no temporary directory for the mask");
  g_setenv ("FURIOS_SWITCH_MASK_DIR", mask, TRUE);

  reads_fd = inotify_init1 (IN_NONBLOCK | IN_CLOEXEC);
  if (reads_fd < 0 || inotify_add_watch (reads_fd, base, IN_OPEN) < 0)
    g_error ("no inotify watch on %s", base);

  if (!gtk_init_check (&argc, &argv)) {
    g_print ("  \033[33mskipped\033[0m - no display to build a GTK widget on\n");
    return 77;
  }

  /* src/plugin-loader.c, phosh_plugin_loader_constructed(). */
  ep = g_io_extension_point_register (PHOSH_PLUGIN_EXTENSION_POINT_STATUS_ICON_WIDGET);
  g_io_extension_point_set_required_type (ep, GTK_TYPE_WIDGET);
  g_io_modules_scan_all_in_directory (argv[1]);

  extension = g_io_extension_point_get_extension_by_name (ep, PLUGIN_NAME);
  if (extension == NULL) {
    fail ("the shell finds it under the name the settings hold",
          "no extension '" PLUGIN_NAME "' after scanning the directory");
    g_print ("\n\033[31m%d of %d checks failed\033[0m\n", failures, checks);
    return 1;
  }
  ok ("the shell finds it under the name the settings hold");

  type = g_io_extension_get_type (extension);
  check_true ("and what it finds is a widget", g_type_is_a (type, GTK_TYPE_WIDGET));

  /* Both switches free, as they are on a phone nobody has touched. */
  set_switch ("cam_switch", "1\n");
  set_switch ("nwk_switch", "1\n");
  widget = g_object_new (type, NULL);
  g_object_ref_sink (widget);

  /* Not "it hides itself in a moment": phosh hands the widget to its box and
     shows the box, and a widget that is visible for even one frame is a
     camera icon flashing up on a phone whose camera is fine. */
  check_true ("both free: nothing on screen, from the first moment",
              !gtk_widget_get_visible (widget));

  /* The show_all phosh runs over its box must not undo that. */
  gtk_widget_show_all (widget);
  check_true ("and the shell's show_all does not bring it out",
              !gtk_widget_get_visible (widget));

  set_switch ("cam_switch", "0\n");
  check_true ("camera engaged: its icon, and only its icon",
              settles_to (widget, TRUE, FALSE));

  set_switch ("nwk_switch", "0\n");
  check_true ("both engaged: both icons", settles_to (widget, TRUE, TRUE));

  set_switch ("cam_switch", "1\n");
  check_true ("camera released: it goes, the other stays",
              settles_to (widget, FALSE, TRUE));

  set_switch ("nwk_switch", "1\n");
  check_true ("both released: the widget goes away again",
              settles_to (widget, FALSE, FALSE));

  /* What must NOT light an icon. A privacy icon that appears on a file it
     could not make sense of is worth nothing - it would be on half the time
     and right by accident. */
  set_switch ("cam_switch", "x\n");
  check_true ("an unexpected value is not an engaged switch",
              settles_to (widget, FALSE, FALSE));

  set_switch ("cam_switch", "");
  check_true ("an empty file is not an engaged switch",
              settles_to (widget, FALSE, FALSE));

  set_switch ("cam_switch", "00000000000000000000\n");
  check_true ("a file that is too long is not an engaged switch",
              settles_to (widget, FALSE, FALSE));

  set_switch ("cam_switch", NULL);
  check_true ("a missing attribute is not an engaged switch",
              settles_to (widget, FALSE, FALSE));

  set_switch ("cam_switch", "0");
  check_true ("and a value without a newline still is one",
              settles_to (widget, TRUE, FALSE));

  /* furios-switch-mask: a slider whose file is in the mask directory does
     nothing, so no icon claims it does. Each step waits for a change, so a
     tick has provably happened in between. */
  set_switch ("nwk_switch", "0\n");
  check_true ("network engaged, not masked: its icon",
              settles_to (widget, TRUE, TRUE));
  set_mask ("nwk_switch", TRUE);
  check_true ("masked: the network icon goes although the switch says engaged",
              settles_to (widget, TRUE, FALSE));
  set_mask ("cam_switch", TRUE);
  check_true ("and a masked camera slider the same way",
              settles_to (widget, FALSE, FALSE));
  set_mask ("cam_switch", FALSE);
  set_mask ("nwk_switch", FALSE);
  check_true ("mask files gone: both count again",
              settles_to (widget, TRUE, TRUE));
  set_switch ("nwk_switch", "1\n");
  settles_to (widget, TRUE, FALSE);

  /* phosh's "Wi-Fi off", "Bluetooth off" and "no internet" while the network
     switch is engaged: they repeat what our icon says and go away - and come
     back after, but only the ones hidden here. Laid out as phosh does it: they
     are not our siblings but sit in box_network left of the clock, each inside
     a revealer, while we sit in the indicator box - both in the "top-bar". */
  {
    GType wifi_type = fake_type ("PhoshWifiInfo");
    GType bt_type = fake_type ("PhoshBtInfo");
    GType conn_type = fake_type ("PhoshConnectivityInfo");
    GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
    GtkWidget *network = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
    GtkWidget *indicators = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
    GtkWidget *icons = g_object_new (type, NULL);
    GtkWidget *wifi = radio_icon (wifi_type, "network-wireless-disabled-symbolic");
    GtkWidget *bt = radio_icon (bt_type, "bluetooth-active-symbolic");
    GtkWidget *conn = radio_icon (conn_type, "network-offline-symbolic");
    GtkWidget *elsewhere = radio_icon (wifi_type, "network-wireless-disabled-symbolic");
    GtkWidget *other_box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
    GtkWidget *revealer = gtk_revealer_new ();

    g_object_ref_sink (box);
    g_object_ref_sink (other_box);
    gtk_widget_set_name (box, "top-bar");
    set_switch ("cam_switch", "1\n");
    gtk_container_add (GTK_CONTAINER (box), network);
    gtk_container_add (GTK_CONTAINER (box), indicators);
    gtk_container_add (GTK_CONTAINER (indicators), icons);
    gtk_container_add (GTK_CONTAINER (revealer), wifi);
    gtk_container_add (GTK_CONTAINER (network), revealer);
    gtk_container_add (GTK_CONTAINER (network), bt);
    gtk_container_add (GTK_CONTAINER (network), conn);
    gtk_container_add (GTK_CONTAINER (other_box), elsewhere);

    set_switch ("nwk_switch", "0\n");
    check_true ("network engaged: phosh's 'Wi-Fi off' in the other box goes",
                visible_settles_to (wifi, FALSE));
    check_true ("and 'no internet' with it", visible_settles_to (conn, FALSE));
    check_true ("a radio that still says on stays",
                gtk_widget_get_visible (bt));
    check_true ("the same icon outside the top bar (quick settings) is left alone",
                gtk_widget_get_visible (elsewhere));

    gtk_image_set_from_icon_name (GTK_IMAGE (bt), "bluetooth-disabled-symbolic",
                                  GTK_ICON_SIZE_MENU);
    check_true ("and 'Bluetooth off' goes once it says so",
                visible_settles_to (bt, FALSE));

    set_switch ("nwk_switch", "1\n");
    check_true ("network released: 'Wi-Fi off' comes back",
                visible_settles_to (wifi, TRUE));
    check_true ("and 'Bluetooth off' too", visible_settles_to (bt, TRUE));
    check_true ("and 'no internet'", visible_settles_to (conn, TRUE));

    gtk_image_set_from_icon_name (GTK_IMAGE (wifi), "network-wireless-signal-good-symbolic",
                                  GTK_ICON_SIZE_MENU);
    set_switch ("nwk_switch", "0\n");
    check_true ("engaged with Wi-Fi still on", visible_settles_to (bt, FALSE));
    check_true ("then 'no internet' is news and stays",
                gtk_widget_get_visible (conn));
    set_switch ("nwk_switch", "1\n");
    visible_settles_to (bt, TRUE);

    gtk_image_set_from_icon_name (GTK_IMAGE (wifi), "network-wireless-disabled-symbolic",
                                  GTK_ICON_SIZE_MENU);
    gtk_widget_set_visible (wifi, FALSE);
    set_switch ("nwk_switch", "0\n");
    check_true ("engaged again", visible_settles_to (bt, FALSE));
    set_switch ("nwk_switch", "1\n");
    visible_settles_to (bt, TRUE);
    check_true ("an icon phosh hid itself is not shown by us",
                !gtk_widget_get_visible (wifi));

    /* The plugin switched off in the settings while the network switch is
       engaged: the widget goes first and the bar stays. What it hid comes
       back with it - nobody else would - and what phosh hid does not. */
    set_switch ("nwk_switch", "0\n");
    check_true ("engaged once more", visible_settles_to (bt, FALSE));
    check_true ("with 'no internet' hidden too", !gtk_widget_get_visible (conn));
    gtk_widget_destroy (icons);
    check_true ("widget gone first: 'Bluetooth off' is back at once",
                gtk_widget_get_visible (bt));
    check_true ("and 'no internet'", gtk_widget_get_visible (conn));
    check_true ("and the icon phosh hid itself stays hidden",
                !gtk_widget_get_visible (wifi));
    set_switch ("nwk_switch", "1\n");

    gtk_widget_destroy (box);
    g_object_unref (box);
    g_object_unref (other_box);
  }

  /* Switched off in the settings, or the panel torn down: the timer goes
     with the widget. If it did not, it would go on reading sysfs in the
     shell's process for as long as the session lasts, with nothing to show
     it in. */
  check_true ("a live widget does read the switches", reads_while_running () > 0);
  gtk_widget_destroy (widget);
  g_object_unref (widget);
  check_true ("the timer goes when the widget does: no read after",
              reads_while_running () == 0);

  /* Nobody looking, nothing read: the timer stops while the panel window is
     unmapped and while phosh has the display off, and each way back starts
     with a read, so the icon is right in the first frame. An offscreen
     window, so nothing appears on the screen of the phone this runs on. */
  {
    GtkWidget *window = gtk_offscreen_window_new ();
    GtkWidget *icons = g_object_new (type, NULL);

    fake_monitors = g_object_new (fake_monitors_get_type (), NULL);
    set_switch ("cam_switch", "1\n");
    set_switch ("nwk_switch", "1\n");
    gtk_container_add (GTK_CONTAINER (window), icons);

    check_true ("in a window not shown yet: no reads",
                reads_while_running () == 0);
    gtk_widget_show (window);
    check_true ("window shown: the switches are read", reads_while_running () > 0);

    gtk_widget_hide (window);
    check_true ("window hidden: no reads", reads_while_running () == 0);
    set_switch ("nwk_switch", "0\n");
    gtk_widget_show (window);
    check_true ("shown again: what changed meanwhile is there at once",
                gtk_widget_get_visible (icons) &&
                gtk_widget_get_visible (image_at (icons, 1)));

    g_object_set (fake_monitors, "power-save-mode", 3, NULL);
    check_true ("display off: no reads", reads_while_running () == 0);
    set_switch ("nwk_switch", "1\n");
    g_object_set (fake_monitors, "power-save-mode", 0, NULL);
    check_true ("display on: read at once", !gtk_widget_get_visible (icons));
    check_true ("and read on the timer again", reads_while_running () > 0);

    gtk_widget_destroy (window);
    check_true ("window and widget gone: no reads", reads_while_running () == 0);
    g_clear_object (&fake_monitors);
  }

  g_print ("\n");
  if (failures == 0)
    g_print ("\033[32mall %d checks passed\033[0m\n", checks);
  else
    g_print ("\033[31m%d of %d checks failed\033[0m\n", failures, checks);

  return failures > 0 ? 1 : 0;
}
