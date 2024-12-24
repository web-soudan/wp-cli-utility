<?php
/**
 * Plugin Name: Admin Color Sunrise Plugin
 * Description: Changes the admin color scheme to "sunrise" only when the plugin is active.
 * Version: 1.0
 * Author: Your Name
 */

// Hook to change admin color when the plugin is activated
add_filter('get_user_option_admin_color', 'override_admin_color_when_active', 10, 3);

function override_admin_color_when_active($result, $option, $user) {
    // Override the admin color scheme to "sunrise" only when this plugin is active
    if ($option === 'admin_color') {
        return 'sunrise';
    }
    return $result;
}

// Hook to restore original functionality when the plugin is deactivated
register_deactivation_hook(__FILE__, 'restore_default_admin_color');

function restore_default_admin_color() {
    // No action needed as the filter will no longer be applied when the plugin is deactivated
}
