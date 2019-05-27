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

namespace AccountManager.Dialogs
{
    /// <summary>
    /// Interaction logic for ImportRuleSelectDialog.xaml
    /// </summary>
    public partial class ImportRuleSelectDialog : UserControl
    {
        public Dictionary<AbstractAccountApi.Rule, string> Rules { get; set; }
        public AbstractAccountApi.Rule SelectedRule { get; set; }

        public ImportRuleSelectDialog(AbstractAccountApi.RuleType ruleType)
        {
            InitializeComponent();
            switch(ruleType)
            {
                case AbstractAccountApi.RuleType.SS_Import:
                    Rules = SmartschoolApi.Rules.Rules.ImportRules;
                    break;
                case AbstractAccountApi.RuleType.WISA_Import:
                    Rules = WisaApi.Rules.Rules.ImportRules;
                    break;
            }
            SelectedRule = Rules.First().Key;
            DataContext = this;
        }

        private void RulePicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            SelectedRule = (AbstractAccountApi.Rule)((e.Source as ComboBox).SelectedValue);
        }
    }
}
