using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
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
using MahApps.Metro.Controls;

namespace AccountManager
{
    /// <summary>
    /// Interaction logic for MainWindow.xaml
    /// </summary>
    public partial class MainWindow : MetroWindow
    {
        static public MainWindow Instance { get; private set; }

        public MainWindow()
        {
            InitializeComponent();
            Instance = this;
            State.App.Instance.Initialize();

            //State.App.Instance.Google.Connect();
            State.App.Instance.Wisa.Connect();
            State.App.Instance.Smartschool.Connect();
            State.App.Instance.Azure.Connect();
        }

        private async Task LoadContent()
        {
            await State.App.Instance.Linked.Groups.ReLink().ConfigureAwait(false);
            await State.App.Instance.Linked.Accounts.ReLink().ConfigureAwait(false);
            await State.App.Instance.Linked.Staff.ReLink().ConfigureAwait(false);

            Application.Current.Dispatcher.Invoke((System.Action)delegate
            {
                Navigate(new Views.Dashboard.DashboardPage());
            });
            Log.AddMessage(AccountApi.Origin.Other, "Build: 1.1.2.62");
        }

        public void Navigate(UserControl page)
        {
            Content.Children.Clear();
            Content.Children.Add(page);
        }

        private async void MetroWindow_Loaded(object sender, RoutedEventArgs e)
        {
            await LoadContent().ConfigureAwait(false);
        }
    }
}
