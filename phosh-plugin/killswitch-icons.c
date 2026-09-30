/*
 * SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
 * SPDX-License-Identifier: MIT
 *
 * The kill switch icons, as a widget inside phosh's own indicator box.
 *
 * Why a plugin and not the layer-shell strip this started as: a strip of our
 * own is a surface stacked over the top bar, and it can only pin its icons a
 * fixed distance from an edge. It cannot see how wide phosh's indicators are
 * at that moment, so anything that appears there - a battery time, a language
 * label, one more revealer - ends up underneath our icons. That is exactly
 * what happened. In the box the icons are laid out by the box: it gives them
 * room, everything else moves over, and nothing can overlap.
 *
 * Where it stands: the box sorts PhoshStatusIcons by priority and puts a
 * plain widget - which is what this is - at the very start, left of every
 * icon. That is the place these belong. They are not a reading about the
 * phone like the battery is; they say a part of it is switched off, and that
 * is read first.
 *
 * This runs in phosh's process, so it does as little as a thing can do: it
 * reads two small sysfs attributes on a timer and shows or hides two images -
 * and, while the network switch is engaged, phosh's own "Wi-Fi off" and
 * "Bluetooth off" icons next to them (see hide_radio_icons).
 * Every failure is "show nothing" - a shell that died over an odd byte in
 * sysfs would be a far worse bargain than a missing icon. It never writes,
 * never calls out, and holds nothing but two booleans.
 *
 * A timer, because there is nothing to wait on: FuriLabs' custom_keys driver
 * does not call sysfs_notify(), measured on the device - poll() on the
 * attributes stays silent through a full switch cycle while the value
 * provably changes. So the interval is the delay before the icon appears.
 */

#include <gtk/gtk.h>
#include <gio/gio.h>
#include <phosh-plugin.h>

/* Where FuriLabs' custom_keys driver exports the two readable switches. The
   environment variable is how the tests point this at a directory of their
   own - the same one the daemon in this project uses. */
#define BASE_DEFAULT "/sys/devices/platform/custom-keys"
#define BASE_ENV     "FURIOS_KILLSWITCH_BASE"

/* The attribute reads "1" while the switch lets the hardware work and "0"
   while it is engaged. Anything else is not an answer - see read_engaged. */
#define ENGAGED_VALUE '0'

/* Long enough for "1\n", short enough that a file which is not ours cannot
   become an icon. */
#define MAX_LEN 8

/* The delay before an icon appears, in seconds. At 2 s the daemon this grew
   out of cost 0.0154 % of one core; this does the same two reads in C.
   The environment variable is the daemon's own, and is here so a test does
   not have to wait out the real interval - never below a second, and never
   long enough to look broken. */
#define POLL_SECONDS 2
#define POLL_ENV     "FURIOS_KILLSWITCH_INTERVAL"
#define POLL_MAX     60

/* phosh's own status icons are drawn at 16px, and the box spaces them 8px
   apart. Both are matched here so the pair reads as part of the row. */
#define ICON_SIZE 16
#define ICON_SPACING 8

/* Amber, not the bar's white: these say something is switched off, and that
   is worth seeing at a glance. The shadow keeps them legible on a light
   wallpaper - the top bar is transparent. */
#define ICON_CSS                                          \
  "image {"                                               \
  "  color: #ffb648;"                                     \
  "  -gtk-icon-shadow: 0 1px 2px rgba(0, 0, 0, 0.6);"     \
  "}"

static const struct {
  const char *attribute;
  const char *icon;
} SWITCHES[] = {
  { "cam_switch", "camera-disabled-symbolic" },
  { "nwk_switch", "network-cellular-disabled-symbolic" },
};

#define N_SWITCHES G_N_ELEMENTS (SWITCHES)

/* Index of the network switch in SWITCHES. */
#define NETWORK_SWITCH 1

/* phosh's icons for the two radios the daemon may take down with the network
   switch. Hidden only while they say "off": one that still shows Wi-Fi on is
   news and stays. */
static const char *const RADIO_TYPES[] = { "PhoshWifiInfo", "PhoshBtInfo" };
#define HIDDEN_BY_US "furios-killswitch-hidden"


#define FURIOS_TYPE_KILLSWITCH_ICONS (furios_killswitch_icons_get_type ())
G_DECLARE_FINAL_TYPE (FuriosKillswitchIcons, furios_killswitch_icons, FURIOS,
                      KILLSWITCH_ICONS, GtkBox)

struct _FuriosKillswitchIcons {
  GtkBox     parent_instance;

  GtkWidget *images[N_SWITCHES];
  char      *base;
  guint      timer_id;
};

G_DEFINE_TYPE (FuriosKillswitchIcons, furios_killswitch_icons, GTK_TYPE_BOX)


/*
 * TRUE only for a switch that says, in as many words, that it is engaged.
 *
 * Not readable, empty, longer than it has any business being, or any value
 * other than the one the driver writes: that is not a "yes", and a privacy
 * icon that lights up on a file it could not read would be worth nothing.
 * The other direction - the icon staying away when it should be there - is
 * why the daemon's `status` command exists and says what it read.
 */
static gboolean
read_engaged (FuriosKillswitchIcons *self, const char *attribute)
{
  g_autofree char *path = g_build_filename (self->base, attribute, NULL);
  g_autofree char *text = NULL;
  gsize len = 0;

  if (!g_file_get_contents (path, &text, &len, NULL))
    return FALSE;

  if (len == 0 || len > MAX_LEN)
    return FALSE;

  /* "0\n" from sysfs, and "0" from a test directory: one character, then the
     end of what was written. */
  return text[0] == ENGAGED_VALUE && (len == 1 || text[1] == '\n');
}


static gboolean
is_radio_icon (GtkWidget *widget)
{
  const char *name = G_OBJECT_TYPE_NAME (widget);

  for (gsize i = 0; i < G_N_ELEMENTS (RADIO_TYPES); i++)
    if (g_strcmp0 (name, RADIO_TYPES[i]) == 0)
      return TRUE;
  return FALSE;
}


static gboolean
says_off (GtkWidget *widget)
{
  g_autofree char *icon = NULL;

  if (!g_object_class_find_property (G_OBJECT_GET_CLASS (widget), "icon-name"))
    return FALSE;
  g_object_get (widget, "icon-name", &icon, NULL);
  return icon && g_str_has_suffix (icon, "-disabled-symbolic");
}


/*
 * With the network switch engaged, our icon already says every radio is off;
 * phosh's "Wi-Fi off" and "Bluetooth off" beside it only repeat that. They are
 * hidden while the switch is engaged and brought back after - but only the
 * ones hidden here, marked on the widget itself, so an icon phosh hid for its
 * own reasons is never shown by us.
 *
 * Only our siblings in the indicator box: the quick settings use the same
 * types, and those are not ours to touch.
 */
static void
hide_radio_icons (FuriosKillswitchIcons *self, gboolean engaged)
{
  GtkWidget *parent = gtk_widget_get_parent (GTK_WIDGET (self));
  g_autoptr (GList) children = NULL;

  if (!GTK_IS_CONTAINER (parent))
    return;

  children = gtk_container_get_children (GTK_CONTAINER (parent));
  for (GList *l = children; l; l = l->next) {
    GtkWidget *child = l->data;
    gboolean ours = GPOINTER_TO_INT (g_object_get_data (G_OBJECT (child),
                                                        HIDDEN_BY_US));

    if (!is_radio_icon (child))
      continue;

    if (engaged && says_off (child)) {
      if (gtk_widget_get_visible (child)) {
        gtk_widget_set_visible (child, FALSE);
        g_object_set_data (G_OBJECT (child), HIDDEN_BY_US, GINT_TO_POINTER (1));
      }
    } else if (ours) {
      g_object_set_data (G_OBJECT (child), HIDDEN_BY_US, NULL);
      gtk_widget_set_visible (child, TRUE);
    }
  }
}


/*
 * One look at both switches.
 *
 * The widget itself goes away when neither is engaged, rather than standing
 * there empty: the box spaces its children, and an empty child would push
 * the indicators over by 8px for nothing.
 */
static void
refresh (FuriosKillswitchIcons *self)
{
  gboolean any = FALSE;

  for (gsize i = 0; i < N_SWITCHES; i++) {
    gboolean engaged = read_engaged (self, SWITCHES[i].attribute);

    gtk_widget_set_visible (self->images[i], engaged);
    any = any || engaged;
  }

  gtk_widget_set_visible (GTK_WIDGET (self), any);
  hide_radio_icons (self, gtk_widget_get_visible (self->images[NETWORK_SWITCH]));
}


/* The interval, from the environment or the default. Anything that is not a
   number in range is the default: a plugin is in no position to complain. */
static guint
poll_seconds (void)
{
  const char *text = g_getenv (POLL_ENV);
  gint64 value;

  if (text == NULL || *text == '\0')
    return POLL_SECONDS;

  value = g_ascii_strtoll (text, NULL, 10);
  if (value < 1 || value > POLL_MAX)
    return POLL_SECONDS;

  return (guint) value;
}


static gboolean
on_timer (gpointer user_data)
{
  refresh (user_data);

  return G_SOURCE_CONTINUE;
}


static void
furios_killswitch_icons_dispose (GObject *object)
{
  FuriosKillswitchIcons *self = FURIOS_KILLSWITCH_ICONS (object);

  g_clear_handle_id (&self->timer_id, g_source_remove);

  G_OBJECT_CLASS (furios_killswitch_icons_parent_class)->dispose (object);
}


static void
furios_killswitch_icons_finalize (GObject *object)
{
  FuriosKillswitchIcons *self = FURIOS_KILLSWITCH_ICONS (object);

  g_clear_pointer (&self->base, g_free);

  G_OBJECT_CLASS (furios_killswitch_icons_parent_class)->finalize (object);
}


static void
furios_killswitch_icons_class_init (FuriosKillswitchIconsClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->dispose = furios_killswitch_icons_dispose;
  object_class->finalize = furios_killswitch_icons_finalize;
}


static void
furios_killswitch_icons_init (FuriosKillswitchIcons *self)
{
  g_autoptr (GtkCssProvider) provider = gtk_css_provider_new ();
  const char *base = g_getenv (BASE_ENV);

  self->base = g_strdup (base && *base ? base : BASE_DEFAULT);

  gtk_orientable_set_orientation (GTK_ORIENTABLE (self),
                                  GTK_ORIENTATION_HORIZONTAL);
  gtk_box_set_spacing (GTK_BOX (self), ICON_SPACING);
  gtk_widget_set_valign (GTK_WIDGET (self), GTK_ALIGN_CENTER);

  gtk_css_provider_load_from_data (provider, ICON_CSS, -1, NULL);

  for (gsize i = 0; i < N_SWITCHES; i++) {
    GtkWidget *image = gtk_image_new_from_icon_name (SWITCHES[i].icon,
                                                     GTK_ICON_SIZE_MENU);

    gtk_image_set_pixel_size (GTK_IMAGE (image), ICON_SIZE);
    /* On this widget alone: the top bar is phosh's, and a screen-wide
       stylesheet from a plugin would reach every image in the shell. */
    gtk_style_context_add_provider (gtk_widget_get_style_context (image),
                                    GTK_STYLE_PROVIDER (provider),
                                    GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    /* Ours to decide, not show_all's. */
    gtk_widget_set_no_show_all (image, TRUE);
    gtk_box_pack_start (GTK_BOX (self), image, FALSE, FALSE, 0);
    self->images[i] = image;
  }

  /* Nothing to say while both switches are free, and phosh shows every widget
     it is handed - so staying away has to be our own doing. */
  gtk_widget_set_no_show_all (GTK_WIDGET (self), TRUE);

  refresh (self);
  self->timer_id = g_timeout_add_seconds (poll_seconds (), on_timer, self);
}


/* --- the GIO module, which is how phosh finds any of this ---------------- */

void
g_io_module_load (GIOModule *module)
{
  /* Pins the module: the type stays valid for as long as phosh runs, which
     is what every other plugin here does. */
  g_type_module_use (G_TYPE_MODULE (module));

  g_io_extension_point_implement (PHOSH_PLUGIN_EXTENSION_POINT_STATUS_ICON_WIDGET,
                                  FURIOS_TYPE_KILLSWITCH_ICONS,
                                  "furios-killswitch",
                                  10);
}


void
g_io_module_unload (GIOModule *module)
{
}


char **
g_io_module_query (void)
{
  char *points[] = { (char *) PHOSH_PLUGIN_EXTENSION_POINT_STATUS_ICON_WIDGET,
                     NULL };

  return g_strdupv (points);
}
