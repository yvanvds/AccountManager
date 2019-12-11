using System;
using System.Collections.ObjectModel;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using static AbstractAccountApi.ObservableProperties;

namespace AccountManager.Views.Accounts
{
    enum GoogleFilterType
    {
        FamilyName,
        GivenName,
        UserID,
        None,
    }
    /// <summary>
    /// Interaction logic for GoogleAccounts.xaml
    /// </summary>
    public partial class GoogleAccounts : UserControl
    {
        public GoogleAccounts()
        {
            InitializeComponent();
            DataContext = new ViewModels.Accounts.GoogleAccounts();
            
        }
    }
}
