#include <gtk/gtk.h>

static void edith_activate(GtkApplication *application, gpointer data) {
    GtkWidget *window = gtk_application_window_new(application);
    gtk_window_set_title(GTK_WINDOW(window), "Edith");
    gtk_window_set_default_size(GTK_WINDOW(window), 760, 520);

    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_margin_top(content, 32);
    gtk_widget_set_margin_bottom(content, 32);
    gtk_widget_set_margin_start(content, 32);
    gtk_widget_set_margin_end(content, 32);

    GtkWidget *title = gtk_label_new("Edith for Ubuntu");
    gtk_widget_add_css_class(title, "title-1");
    gtk_label_set_xalign(GTK_LABEL(title), 0);
    gtk_box_append(GTK_BOX(content), title);

    GtkWidget *subtitle = gtk_label_new(
        "The native GTK shell and shared extension capability layer are ready.");
    gtk_label_set_wrap(GTK_LABEL(subtitle), TRUE);
    gtk_label_set_xalign(GTK_LABEL(subtitle), 0);
    gtk_box_append(GTK_BOX(content), subtitle);

    gtk_window_set_child(GTK_WINDOW(window), content);
    gtk_window_present(GTK_WINDOW(window));
}

static int edith_gtk_run(void) {
    GtkApplication *application = gtk_application_new(
        "com.pulkit.Edith", G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(application, "activate", G_CALLBACK(edith_activate), NULL);
    int status = g_application_run(G_APPLICATION(application), 0, NULL);
    g_object_unref(application);
    return status;
}
