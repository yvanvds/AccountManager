using MaterialDesignThemes.Wpf;
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

namespace AccountManager.Views.Dialogs
{
    /// <summary>
    /// Interaction logic for ImportRuleSelectDialog.xaml
    /// </summary>
    public partial class ImportRuleSelectDialog : UserControl
    {
        public Dictionary<AccountApi.Rule, string> Rules { get; set; }
        public AccountApi.Rule SelectedRule { get; set; }

        public ImportRuleSelectDialog(AccountApi.RuleType ruleType)
        {
            InitializeComponent();
            switch(ruleType)
            {
                case AccountApi.RuleType.SS_Import:
                    Rules = AccountApi.Rules.ImportRules.SmartschoolRules;
                    break;
                case AccountApi.RuleType.WISA_Import:
                    Rules = AccountApi.Rules.ImportRules.WisaRules;
                    break;
            }
            SelectedRule = Rules.First().Key;
            DataContext = this;
        }

        private void RulePicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            SelectedRule = (AccountApi.Rule)((e.Source as ComboBox).SelectedValue);
        }
    }
}
