using System;
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
using static AbstractAccountApi.ObservableProperties;

namespace AccountManager.Views.Dialogs
{
    /// <summary>
    /// Interaction logic for AD_AskForPassword.xaml
    /// </summary>
    public partial class AD_AskForPassword : UserControl
    {
        public string Username { get; set; }
        public string Password { get; set; }

        public AD_AskForPassword(string username)
        {
            InitializeComponent();
            nameBox.Text = username;
        }

        private void AcceptButton_Click(object sender, RoutedEventArgs e)
        {
            Username = nameBox.Text.Trim();
            Password = passwordBox.Password.Trim();
        }

        private void OnKeyDownHandler(object sender, KeyEventArgs e)
        {
            //if (e.Key == Key.Return)
            //{
            //    Username = nameBox.Text.Trim();
            //    Password = passwordBox.Password.Trim();
            //    Visibility = Visibility.Collapsed;
            //}
        }
    }
}

