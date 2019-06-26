using System.Windows.Controls;

namespace AccountManager.Accounts
{
    /// <summary>
    /// Interaction logic for AccountsPage.xaml
    /// </summary>
    public partial class AccountsPage : UserControl
    {
        public Data Data { get => Data.Instance; }

        public AccountsPage()
        {
            InitializeComponent();
            if(!Data.Instance.ShowDebugInterface)
            {
                Tabs.Items.Remove(WisaTab);
                Tabs.Items.Remove(ADTab);
                Tabs.Items.Remove(SmartschoolTab);
                Tabs.Items.Remove(GoogleTab);
            }
            
        }
    }
}
