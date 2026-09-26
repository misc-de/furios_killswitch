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
 * environment variable the daemon's tests use. Nothing in this test touches
 * the real ones, and it needs no phone: what it checks is the part that is
 * ours - which files make an icon appear, and which do not.
 */

#include <gtk/gtk.h>
#include <gio/gio.h>
#include <glib/gstdio.h>
#include <phosh-plugin.h>

#define PLUGIN_NAME "furios-killswitch"

static int checks = 0;
static int failures = 0;
static char *base = NULL;


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

  /* Switched off in the settings, or the panel torn down: the timer goes
     with the widget. If it did not, it would go on reading sysfs in the
     shell's process for as long as the session lasts, with nothing to show
     it in. */
  gtk_widget_destroy (widget);
  g_object_unref (widget);
  set_switch ("nwk_switch", "0\n");
  g_usleep (1200 * 1000);
  while (g_main_context_iteration (NULL, FALSE))
    ;
  ok ("the timer goes when the widget does (no use-after-free here)");

  g_print ("\n");
  if (failures == 0)
    g_print ("\033[32mall %d checks passed\033[0m\n", checks);
  else
    g_print ("\033[31m%d of %d checks failed\033[0m\n", failures, checks);

  return failures > 0 ? 1 : 0;
}
