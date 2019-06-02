using AbstractAccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class DoNotImportClassGroupFromSmartschool : IAction
    {
        public string Header => "Klas Negeren";

        public string Description => "Importeer deze klas niet uit Smartschool. Doe dit wanneer de klas moet bestaan in smartschool maar " +
            "niet gelinkt is aan een klas in Wisa en Active Directory.";


        public bool CanBeApplied => true;

        public ObservableProperties.Prop<bool> InProgress { get; set; } = new ObservableProperties.Prop<bool>() { Value = false };

        public async Task Apply(LinkedGroup linkedGroup)
        {
            throw new NotImplementedException();
        }

        public DoNotImportClassGroupFromSmartschool(SmartschoolApi.Group group)
        {
            this.group = group;
        }

        SmartschoolApi.Group group;
    }
}
