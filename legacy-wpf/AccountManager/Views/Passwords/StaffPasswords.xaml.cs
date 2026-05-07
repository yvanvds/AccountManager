using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
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

namespace AccountManager.Views.Passwords
{

    /// <summary>
    /// Interaction logic for StaffPasswords.xaml
    /// </summary>
    public partial class StaffPasswords : UserControl
    {

        public StaffPasswords()
        {
            InitializeComponent();
            DataContext = new ViewModels.Passwords.StaffPasswords();
            Editor.Visibility = Visibility.Collapsed;
        }

        private void DataGrid_SelectedCellsChanged(object sender, SelectedCellsChangedEventArgs e)
        {
            var account = ((sender as DataGrid).SelectedItem as AccountApi.Smartschool.Account);
            Editor.Visibility = Visibility.Visible;
            Editor.Account = account;
        }

        private void AddAccountButton_Click(object sender, RoutedEventArgs e)
        {
            Editor.Visibility = Visibility.Collapsed;
        }
    }
}
