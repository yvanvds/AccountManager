using System;
using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Controls;
using static AbstractAccountApi.ObservableProperties;

namespace AccountManager.Views.Accounts
{
    /// <summary>
    /// Interaction logic for WisaAccounts.xaml
    /// </summary>
    public partial class WisaAccounts : UserControl
    {

        public WisaAccounts()
        {
            InitializeComponent();
            DataContext = new ViewModels.Accounts.WisaAccounts();
        }

    }
}
