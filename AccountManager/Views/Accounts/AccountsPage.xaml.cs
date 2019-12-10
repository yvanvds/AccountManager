using System.Windows.Controls;

namespace AccountManager.Views.Accounts
{
    /// <summary>
    /// Interaction logic for AccountsPage.xaml
    /// </summary>
    public partial class AccountsPage : UserControl
    {
        ViewModels.Accounts.AccountsPage viewModel = new ViewModels.Accounts.AccountsPage();
        bool debugTabsAreShown = true;

        public AccountsPage()
        {
            InitializeComponent();
            DataContext = viewModel;

            viewModel.PropertyChanged += (sender, args) => UpdateTabs();
        }

        public void UpdateTabs()
        {
            if (!viewModel.DebugMode && debugTabsAreShown)
            {
                Tabs.Items.Remove(WisaTab);
                Tabs.Items.Remove(ADTab);
                Tabs.Items.Remove(SmartschoolTab);
                Tabs.Items.Remove(GoogleTab);
            } else if (viewModel.DebugMode && !debugTabsAreShown)
            {
                Tabs.Items.Add(WisaTab);
                Tabs.Items.Add(ADTab);
                Tabs.Items.Add(SmartschoolTab);
                Tabs.Items.Add(GoogleTab);
            }
        }
    }
}
