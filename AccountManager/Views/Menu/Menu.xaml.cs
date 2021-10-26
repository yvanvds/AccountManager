﻿using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Navigation;
using System.Windows.Shapes;

namespace AccountManager.Views.Menu
{
    /// <summary>
    /// Interaction logic for Menu.xaml
    /// </summary>
    public partial class Menu : UserControl
    {

        public Menu()
        {
            InitializeComponent();
        }

        private void DashboardButton_Click(object sender, RoutedEventArgs e)
        {
            MainWindow.Instance.Navigate(new Views.Dashboard.DashboardPage());
        }

        private void GroupsButton_Click(object sender, RoutedEventArgs e)
        {
            MainWindow.Instance.Navigate(new Groups.GroupsPage());
        }

        private void UsersButton_Click(object sender, RoutedEventArgs e)
        {
            MainWindow.Instance.Navigate(new Views.Accounts.AccountsPage());
        }

        private void PasswordsButton_Click(object sender, RoutedEventArgs e)
        {
            MainWindow.Instance.Navigate(new Views.Passwords.PasswordPage());
        }

        private void ActionsButton_Click(object sender, RoutedEventArgs e)
        {
            MainWindow.Instance.Navigate(new Views.Actions.ActionsPage());
        }

        private void SettingsButton_Click(object sender, RoutedEventArgs e)
        {
            MainWindow.Instance.Navigate(new Views.Settings.SettingsPage());
        }
    }
}
