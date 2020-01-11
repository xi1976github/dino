using Gee;
using Gtk;
using Pango;

using Dino.Entities;

namespace Dino.Ui.ConversationSummary {

[GtkTemplate (ui = "/im/dino/Dino/conversation_summary/view.ui")]
public class ConversationView : Box, Plugins.ConversationItemCollection, Plugins.NotificationCollection {

    public Conversation? conversation { get; private set; }

    [GtkChild] public ScrolledWindow scrolled;
    [GtkChild] private Revealer notification_revealer;
    [GtkChild] private Box notifications;
    [GtkChild] private Box main;
    [GtkChild] private Stack stack;

    private StreamInteractor stream_interactor;
    private Gee.TreeSet<Plugins.MetaConversationItem> content_items = new Gee.TreeSet<Plugins.MetaConversationItem>(compare_meta_items);
    private Gee.TreeSet<Plugins.MetaConversationItem> meta_items = new TreeSet<Plugins.MetaConversationItem>(compare_meta_items);
    private Gee.HashMap<Plugins.MetaConversationItem, ConversationItemSkeleton> item_item_skeletons = new Gee.HashMap<Plugins.MetaConversationItem, ConversationItemSkeleton>();
    private Gee.HashMap<Plugins.MetaConversationItem, Widget> widgets = new Gee.HashMap<Plugins.MetaConversationItem, Widget>();
    private Gee.List<ConversationItemSkeleton> item_skeletons = new Gee.ArrayList<ConversationItemSkeleton>();
    private ContentProvider content_populator;
    private SubscriptionNotitication subscription_notification;

    private double? was_value;
    private double? was_upper;
    private double? was_page_size;

    private Mutex reloading_mutex = Mutex();
    private bool animate = false;
    private bool firstLoad = true;
    private bool at_current_content = true;
    private bool reload_messages = true;

//xi (c) by ThibG
    enum Target {
      URI_LIST,
      STRING
    }

    const TargetEntry[] target_list = {
      { "text/uri-list",0, Target.URI_LIST},
    };
//xi (c) by ThibG

    public ConversationView init(StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;
        scrolled.vadjustment.notify["upper"].connect_after(on_upper_notify);
        scrolled.vadjustment.notify["value"].connect(on_value_notify);

        content_populator = new ContentProvider(stream_interactor);
        subscription_notification = new SubscriptionNotitication(stream_interactor);

        add_meta_notification.connect(on_add_meta_notification);
        remove_meta_notification.connect(on_remove_meta_notification);

        Application app = GLib.Application.get_default() as Application;
        app.plugin_registry.register_conversation_addition_populator(new ChatStatePopulator(stream_interactor));
        app.plugin_registry.register_conversation_addition_populator(new DateSeparatorPopulator(stream_interactor));

        Timeout.add_seconds(60, () => {
            foreach (ConversationItemSkeleton item_skeleton in item_skeletons) {
                item_skeleton.update_time();
            }
            return true;
        });

//xi
drag_dest_unset(main);
drag_dest_set(scrolled, DestDefaults.ALL, target_list, Gdk.DragAction.COPY);
scrolled.drag_data_received.connect(this.on_drag_data_received);
//xi
        return this;
    }

    public void initialize_for_conversation(Conversation? conversation) {
        // Workaround for rendering issues
        if (firstLoad) {
            main.visible = false;
            Idle.add(() => {
                main.visible=true;
                return false;
            });
            firstLoad = false;
        }
        stack.set_visible_child_name("void");
        clear();
        initialize_for_conversation_(conversation);
        display_latest();
        stack.set_visible_child_name("main");
    }

    public void initialize_around_message(Conversation conversation, ContentItem content_item) {
        stack.set_visible_child_name("void");
        clear();
        initialize_for_conversation_(conversation);
        Gee.List<ContentMetaItem> before_items = content_populator.populate_before(conversation, content_item, 40);
        foreach (ContentMetaItem item in before_items) {
            do_insert_item(item);
        }
        ContentMetaItem meta_item = content_populator.get_content_meta_item(content_item);
        meta_item.can_merge = false;
        Widget w = insert_new(meta_item);
        content_items.add(meta_item);
        meta_items.add(meta_item);

        Gee.List<ContentMetaItem> after_items = content_populator.populate_after(conversation, content_item, 40);
        foreach (ContentMetaItem item in after_items) {
            do_insert_item(item);
        }
        if (after_items.size == 40) {
            at_current_content = false;
        }

        // Compute where to jump to for centered message, jump, highlight.
        reload_messages = false;
        Timeout.add(700, () => {
            int h = 0, i = 0;
            bool @break = false;
            main.@foreach((widget) => {
                if (widget == w || @break) {
                    @break = true;
                    return;
                }
                h += widget.get_allocated_height();
                i++;
            });
            scrolled.vadjustment.value = h - scrolled.vadjustment.page_size * 1/3;
            w.get_style_context().add_class("highlight-once");
            reload_messages = true;
            stack.set_visible_child_name("main");
            return false;
        });
    }

    private void initialize_for_conversation_(Conversation? conversation) {
        // Deinitialize old conversation
        Dino.Application app = Dino.Application.get_default();
        if (this.conversation != null) {
            foreach (Plugins.ConversationItemPopulator populator in app.plugin_registry.conversation_addition_populators) {
                populator.close(conversation);
            }
            foreach (Plugins.NotificationPopulator populator in app.plugin_registry.notification_populators) {
                populator.close(conversation);
            }
        }

        // Clear data structures
        clear_notifications();
        this.conversation = conversation;

        // Init for new conversation
        foreach (Plugins.ConversationItemPopulator populator in app.plugin_registry.conversation_addition_populators) {
            populator.init(conversation, this, Plugins.WidgetType.GTK);
        }
        content_populator.init(this, conversation, Plugins.WidgetType.GTK);
        subscription_notification.init(conversation, this);

        animate = false;
        Timeout.add(20, () => { animate = true; return false; });
    }

    private void display_latest() {
        Gee.List<ContentMetaItem> items = content_populator.populate_latest(conversation, 40);
        foreach (ContentMetaItem item in items) {
            do_insert_item(item);
        }
        Application app = GLib.Application.get_default() as Application;
        foreach (Plugins.NotificationPopulator populator in app.plugin_registry.notification_populators) {
            populator.init(conversation, this, Plugins.WidgetType.GTK);
        }
        Idle.add(() => { on_value_notify(); return false; });
    }

    public void insert_item(Plugins.MetaConversationItem item) {
        if (meta_items.size > 0) {
            bool after_last = meta_items.last().sort_time.compare(item.sort_time) <= 0;
            bool within_range = meta_items.last().sort_time.compare(item.sort_time) > 0 && meta_items.first().sort_time.compare(item.sort_time) < 0;
            bool accept = within_range || (at_current_content && after_last);
            if (!accept) {
                return;
            }
        }
        do_insert_item(item);
    }

    public void do_insert_item(Plugins.MetaConversationItem item) {
        lock (meta_items) {
            insert_new(item);
            if (item as ContentMetaItem != null) {
                content_items.add(item);
            }
            meta_items.add(item);
        }

        inserted_item(item);
    }
//xi (c) ThibG
    public void on_drag_data_received(Widget widget, Gdk.DragContext context,
                                       int x, int y,
                                       SelectionData selection_data,
                                       uint target_type, uint time) {
         if ((selection_data != null) && (selection_data.get_length() >= 0)) {
             switch (target_type) {
             case Target.URI_LIST:
                 string[] uris = selection_data.get_uris();
                 for (int i = 0; i < uris.length; i++) {
                   try {
                     string filename = Filename.from_uri(uris[i]);
                     stream_interactor.get_module(FileManager.IDENTITY).send_file(filename, conversation);
                   } catch (Error err) {
                   }
                 }
                 break;
             default:
                 break;
             }
         }
     }
//xi (c) ThibG


    private void remove_item(Plugins.MetaConversationItem item) {
        ConversationItemSkeleton? skeleton = item_item_skeletons[item];
        if (skeleton != null) {
            widgets[item].destroy();
            widgets.unset(item);
            skeleton.destroy();
            item_skeletons.remove(skeleton);
            item_item_skeletons.unset(item);

            content_items.remove(item);
            meta_items.remove(item);
        }

        removed_item(item);
    }

    public void on_add_meta_notification(Plugins.MetaConversationNotification notification) {
        Widget? widget = (Widget) notification.get_widget(Plugins.WidgetType.GTK);
        if (widget != null) {
            add_notification(widget);
        }
    }

    public void on_remove_meta_notification(Plugins.MetaConversationNotification notification){
        Widget? widget = (Widget) notification.get_widget(Plugins.WidgetType.GTK);
        if (widget != null) {
            remove_notification(widget);
        }
    }

    public void add_notification(Widget widget) {
        notifications.add(widget);
        Timeout.add(20, () => {
            notification_revealer.transition_duration = 200;
            notification_revealer.reveal_child = true;
            return false;
        });
    }

    public void remove_notification(Widget widget) {
        notification_revealer.reveal_child = false;
        widget.destroy();
    }

    private Widget insert_new(Plugins.MetaConversationItem item) {
        Plugins.MetaConversationItem? lower_item = meta_items.lower(item);

        // Fill datastructure
        ConversationItemSkeleton item_skeleton = new ConversationItemSkeleton(stream_interactor, conversation, item) { visible=true };
        item_item_skeletons[item] = item_skeleton;
        int index = lower_item != null ? item_skeletons.index_of(item_item_skeletons[lower_item]) + 1 : 0;
        item_skeletons.insert(index, item_skeleton);

        // Insert widget
        Widget insert = item_skeleton;
        if (animate) {
            Revealer revealer = new Revealer() {transition_duration = 200, transition_type = RevealerTransitionType.SLIDE_UP, visible = true};
            revealer.add(item_skeleton);
            insert = revealer;
            main.add(insert);
            revealer.reveal_child = true;
        } else {
            main.add(insert);
        }
        widgets[item] = insert;
        main.reorder_child(insert, index);

        if (lower_item != null) {
            if (can_merge(item, lower_item)) {
                ConversationItemSkeleton lower_skeleton = item_item_skeletons[lower_item];
                item_skeleton.show_skeleton = false;
                lower_skeleton.last_group_item = false;
            }
        }

        Plugins.MetaConversationItem? upper_item = meta_items.higher(item);
        if (upper_item != null) {
            if (!can_merge(upper_item, item)) {
                ConversationItemSkeleton upper_skeleton = item_item_skeletons[upper_item];
                upper_skeleton.show_skeleton = true;
            }
        }

        // If an item from the past was added, add everything between that item and the (post-)first present item
        if (index == 0) {
            Dino.Application app = Dino.Application.get_default();
            if (item_skeletons.size == 1) {
                foreach (Plugins.ConversationAdditionPopulator populator in app.plugin_registry.conversation_addition_populators) {
                    populator.populate_timespan(conversation, item.sort_time, new DateTime.now_utc());
                }
            } else {
                foreach (Plugins.ConversationAdditionPopulator populator in app.plugin_registry.conversation_addition_populators) {
                    populator.populate_timespan(conversation, item.sort_time, meta_items.higher(item).sort_time);
                }
            }
        }
        return insert;
    }

    private bool can_merge(Plugins.MetaConversationItem upper_item /*more recent, displayed below*/, Plugins.MetaConversationItem lower_item /*less recent, displayed above*/) {
        return upper_item.display_time != null && lower_item.display_time != null &&
            upper_item.display_time.difference(lower_item.display_time) < TimeSpan.MINUTE &&
            upper_item.jid.equals(lower_item.jid) &&
            upper_item.encryption == lower_item.encryption &&
            (upper_item.mark == Message.Marked.WONTSEND) == (lower_item.mark == Message.Marked.WONTSEND);
    }

    private void on_upper_notify() {
        if (was_upper == null || scrolled.vadjustment.value >  was_upper - was_page_size - 1) { // scrolled down or content smaller than page size
            if (at_current_content) {
                scrolled.vadjustment.value = scrolled.vadjustment.upper - scrolled.vadjustment.page_size; // scroll down
            }
        } else if (scrolled.vadjustment.value < scrolled.vadjustment.upper - scrolled.vadjustment.page_size - 1) {
            scrolled.vadjustment.value = scrolled.vadjustment.upper - was_upper + scrolled.vadjustment.value; // stay at same content
        }
        was_upper = scrolled.vadjustment.upper;
        was_page_size = scrolled.vadjustment.page_size;
        was_value = scrolled.vadjustment.value;
        reloading_mutex.trylock();
        reloading_mutex.unlock();
    }

    private void on_value_notify() {
        if (scrolled.vadjustment.value < 400) {
            load_earlier_messages();
        } else if (scrolled.vadjustment.upper - (scrolled.vadjustment.value + scrolled.vadjustment.page_size) < 400) {
            load_later_messages();
        }
    }

    private void load_earlier_messages() {
        was_value = scrolled.vadjustment.value;
        if (!reloading_mutex.trylock()) return;
        if (meta_items.size > 0) {
            Gee.List<ContentMetaItem> items = content_populator.populate_before(conversation, (content_items.first() as ContentMetaItem).content_item, 20);
            foreach (ContentMetaItem item in items) {
                do_insert_item(item);
            }
        } else {
            reloading_mutex.unlock();
        }
    }

    private void load_later_messages() {
        if (!reloading_mutex.trylock()) return;
        if (meta_items.size > 0 && !at_current_content) {
            Gee.List<ContentMetaItem> items = content_populator.populate_after(conversation, (content_items.last() as ContentMetaItem).content_item, 20);
            if (items.size == 0) {
                at_current_content = true;
            }
            foreach (ContentMetaItem item in items) {
                do_insert_item(item);
            }
        } else {
            reloading_mutex.unlock();
        }
    }

    private static int compare_meta_items(Plugins.MetaConversationItem a, Plugins.MetaConversationItem b) {
        int cmp1 = a.sort_time.compare(b.sort_time);
        if (cmp1 == 0) {
            double cmp2 = a.seccondary_sort_indicator - b.seccondary_sort_indicator;
            if (cmp2 == 0) {
                return (int) (a.tertiary_sort_indicator - b.tertiary_sort_indicator);
            }
            return (int) cmp2;
        }
        return cmp1;
    }

    private void clear() {
        was_upper = null;
        was_page_size = null;
        content_items.clear();
        meta_items.clear();
        item_skeletons.clear();
        item_item_skeletons.clear();
        widgets.clear();
        main.@foreach((widget) => { widget.destroy(); });
    }

    private void clear_notifications() {
        notifications.@foreach((widget) => { widget.destroy(); });
        notification_revealer.transition_duration = 0;
        notification_revealer.set_reveal_child(false);
    }
}

}
